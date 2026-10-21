#!/usr/bin/env bash
# Offline checks of ops/restore.sh's dump parser (README R6 shapes). Every
# run points --target at a closed port, so a dump that passes the parser ends
# in psql's "connection refused" (rc=2) without touching any database, and a
# refusal is rc=3 before any connection. Each shape has an expected exit code
# and an expected fragment of the script's output.
#   R1–R6   shapes the parser must accept (pg_dump -t default, quoted
#           identifiers, the column order of an upgraded database, CRLF,
#           setval without pg_catalog., another sequence's setval alongside)
#   R7–R18  shapes it must refuse, with the right reason
#   R19–R22 the real exports: `supabase db dump --data-only` (INSERT format),
#           `--use-copy` (whole database), `--use-copy -s public` (every
#           public table), and the R6 pg_dump command (accepted). These need
#           the supabase CLI and the local stack; without them they are
#           INVALID, not PASS.
# RESTORE_SH= points at another copy of the script (the negative controls).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
RESTORE=${RESTORE_SH:-$HERE/../ops/restore.sh}
CLOSED=${CLOSED_TARGET:-postgresql://postgres:postgres@127.0.0.1:1/postgres}
DB=${SUPABASE_DB:-postgresql://postgres:postgres@127.0.0.1:54322/postgres}
PG_DUMP=${PG_DUMP:-$(command -v pg_dump || echo /opt/homebrew/opt/libpq/bin/pg_dump)}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fails=0; invalid=0
rec() { # id, verdict(PASS/FAIL/INVALID), claim, observed
  case $2 in FAIL) fails=$((fails + 1));; INVALID) invalid=$((invalid + 1));; esac
  printf '%s %-4s %s\n      %s\n' "$2" "$1" "$3" "$4"
}
run() { "$RESTORE" --target "$CLOSED" --data "$1" --replace 2>&1; }
# shape id file expected_rc expected_fragment claim
shape() {
  local id=$1 f=$2 want_rc=$3 want=$4 claim=$5 out rc
  out=$(run "$f"); rc=$?
  local line; line=$(echo "$out" | grep -E 'refusing|connection|refused' | head -1 | cut -c1-200)
  if [[ $rc == "$want_rc" && $out == *"$want"* ]] && { [[ $want_rc != 2 ]] || [[ $out != *refusing* ]]; }; then
    rec "$id" PASS "$claim" "rc=$rc: $line"
  else
    rec "$id" FAIL "$claim" "rc=$rc (want $want_rc, fragment '$want'): $line"
  fi
}

U1=11111111-1111-1111-1111-111111111111; U2=22222222-2222-2222-2222-222222222222; V1=33333333-3333-3333-3333-333333333333
E0=aaaaaaaa-0000-0000-0000-000000000001
base() { # pg_dump --data-only -t shape
  printf '%s\n' '--' '-- PostgreSQL database dump' '--' '' 'SET statement_timeout = 0;' "SET lock_timeout = 0;" '' \
    '--' '-- Data for Name: events; Type: TABLE DATA; Schema: public; Owner: postgres' '--' '' \
    'COPY public.events (id, user_id, kind, title, seq, version_id) FROM stdin;'
  printf '%s\t%s\ttodo\tbase row\t5\t%s\n' "$U1" "$U2" "$V1"
  printf '%s\n' '\.' '' 'COPY public.sync_epoch (epoch, paused, rollback, restores, changed_at) FROM stdin;'
  printf '%s\tf\tf\t[]\t2026-01-01 00:00:00+00\n' "$E0"
  printf '%s\n' '\.' '' 'COPY public.sync_versions (user_id, tbl, id, version_id, parent_version_id, restored_from_version_id, seq, created_at) FROM stdin;'
  printf '%s\tevents\t%s\t%s\t\\N\t\\N\t5\t2026-01-01 00:00:00+00\n' "$U2" "$U1" "$V1"
  printf '%s\n' '\.' '' '--' '-- Name: sync_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres' '--' '' \
    "SELECT pg_catalog.setval('public.sync_seq', 5, true);" '' '--' '-- PostgreSQL database dump complete' '--'
}
base > "$TMP/base.sql"
ACCEPT="connection"

shape R1 "$TMP/base.sql" 2 "$ACCEPT" "the R6 pg_dump shape passes the parser (setval 1, sync_epoch 1 row, sync_versions 1 block) and the script goes on to connect"
sed -e 's/^COPY public\.\([a-z_]*\)/COPY "public"."\1"/' -e "s/setval('public.sync_seq'/setval('\"public\".\"sync_seq\"'/" "$TMP/base.sql" > "$TMP/quoted.sql"
shape R2 "$TMP/quoted.sql" 2 "$ACCEPT" "quoted identifiers (COPY \"public\".\"x\", setval('\"public\".\"sync_seq\"')) pass"
sed -e 's/^COPY public.sync_epoch (epoch, paused, rollback, restores, changed_at)/COPY public.sync_epoch (changed_at, paused, epoch, rollback, restores)/' \
    -e "s/^$E0\tf\tf\t\[\]\t2026-01-01 00:00:00+00$/2026-01-01 00:00:00+00\tf\t$E0\tf\t[]/" "$TMP/base.sql" > "$TMP/order.sql"
out=$(run "$TMP/order.sql"); rc=$?
if [[ $rc == 2 && $out == *"(epoch=$E0)"* ]]; then rec R3 PASS "the column order of an upgraded database (epoch not first) still yields the dump's epoch" "rc=$rc: $(echo "$out" | grep -o 'sync_epoch rows=[^,]*' | head -1)"; else rec R3 FAIL "the column order of an upgraded database (epoch not first) still yields the dump's epoch" "rc=$rc: $(echo "$out" | head -2 | tr '\n' ' ' | cut -c1-200)"; fi
sed 's/$/\r/' "$TMP/base.sql" > "$TMP/crlf.sql"
shape R4 "$TMP/crlf.sql" 2 "$ACCEPT" "CRLF line endings are tolerated (the block terminators still close)"
sed "s/SELECT pg_catalog.setval('public.sync_seq'/SELECT setval('public.sync_seq'/" "$TMP/base.sql" > "$TMP/setval_noprefix.sql"
shape R5 "$TMP/setval_noprefix.sql" 2 "$ACCEPT" "a setval without the pg_catalog. prefix is recognised"
{ cat "$TMP/base.sql"; echo "SELECT pg_catalog.setval('public.other_seq', 9, true);"; } > "$TMP/othersetval.sql"
shape R6 "$TMP/othersetval.sql" 2 "$ACCEPT" "another sequence's setval alongside is left alone (only sync_seq's is counted)"

{ cat "$TMP/base.sql"; printf '%s\n' 'COPY public.sync_versions (user_id, tbl, id, version_id, parent_version_id, restored_from_version_id, seq, created_at) FROM stdin;' '\.'; } > "$TMP/twoversions.sql"
shape R7 "$TMP/twoversions.sql" 3 "exactly one public.sync_versions block (found 2)" "two sync_versions blocks -> refused as 'exactly one block'"
awk '/^COPY public\.sync_versions /{skip=1; next} skip && /^\\\.$/{skip=0; next} !skip{print}' "$TMP/base.sql" > "$TMP/noversions.sql"
shape R8 "$TMP/noversions.sql" 3 "must include public.sync_versions" "no sync_versions block -> refused as 'the export must include sync_versions'"
python3 - "$TMP/base.sql" "$TMP/colinserts.sql" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
out = []; skip = False; cols = ""; tbl = ""
for line in open(src):
    line = line.rstrip("\n")
    if skip:
        if line == "\\.": skip = False; continue
        vals = ", ".join("'" + v + "'" if v != "\\N" else "NULL" for v in line.split("\t"))
        out.append(f'INSERT INTO "public"."{tbl}" ({cols}) VALUES ({vals});'); continue
    if line.startswith("COPY public."):
        tbl = line.split()[1].split(".")[1]; cols = ", ".join('"' + c.strip() + '"' for c in line[line.index("(")+1:line.index(")")].split(",")); skip = True; continue
    out.append(line)
open(dst, "w").write("\n".join(out) + "\n")
PY
shape R9 "$TMP/colinserts.sql" 3 "only COPY format is accepted" "an INSERT-format dump (supabase db dump --data-only, --column-inserts) -> refused as 'only COPY format'"
sed 's/^COPY public\./COPY /' "$TMP/base.sql" > "$TMP/noschema.sql"
shape R10 "$TMP/noschema.sql" 3 "without a schema prefix" "COPY blocks without a schema prefix -> refused (cannot be classified)"
sed 's/^COPY public\.sync_versions /COPY public.sync_versions_p2026 /' "$TMP/base.sql" > "$TMP/partition.sql"
shape R11 "$TMP/partition.sql" 3 "outside the synced set (sync_versions_p2026)" "a partition-child table name -> refused as a public table outside the synced set"
sed "s/^$E0\tf\tf\t\[\]\t2026-01-01 00:00:00+00$/&\nbbbbbbbb-0000-0000-0000-000000000002\tf\tf\t[]\t2026-01-02 00:00:00+00/" "$TMP/base.sql" > "$TMP/tworows.sql"
shape R12 "$TMP/tworows.sql" 3 "exactly one public.sync_epoch row (blocks=1 rows=2)" "two sync_epoch rows -> refused"
sed "/^$E0\tf\tf\t\[\]\t2026-01-01 00:00:00+00$/d" "$TMP/base.sql" > "$TMP/zerorows.sql"
shape R13 "$TMP/zerorows.sql" 3 "exactly one public.sync_epoch row (blocks=1 rows=0)" "an empty sync_epoch block -> refused"
awk '/^COPY public\.sync_epoch /{skip=1; next} skip && /^\\\.$/{skip=0; next} !skip{print}' "$TMP/base.sql" > "$TMP/noepoch.sql"
shape R14 "$TMP/noepoch.sql" 3 "exactly one public.sync_epoch row (blocks=0 rows=0)" "no sync_epoch block -> refused"
{ printf '%s\n' 'COPY auth.users (id, email) FROM stdin;' "$U2	someone@local.test" '\.' ''; cat "$TMP/base.sql"; } > "$TMP/otherschema.sql"
shape R15 "$TMP/otherschema.sql" 3 "outside the public schema (auth.users)" "a data block of another schema (a whole-database export) -> refused with the R6 hint"
{ printf '%s\n' 'COPY public.api_keys (id, user_id) FROM stdin;' "$U1	$U2" '\.' ''; cat "$TMP/base.sql"; } > "$TMP/otherpublic.sql"
shape R16 "$TMP/otherpublic.sql" 3 "outside the synced set (api_keys)" "a data block of a public table outside the synced set -> refused with the R6 hint"
{ cat "$TMP/base.sql"; echo "SELECT pg_catalog.setval('public.sync_seq', 5, true);"; } > "$TMP/twosetval.sql"
shape R17 "$TMP/twosetval.sql" 3 "exactly one setval of public.sync_seq (found 2)" "two sync_seq setval lines -> refused"
grep -v "setval('public.sync_seq'" "$TMP/base.sql" > "$TMP/nosetval.sql"
shape R18 "$TMP/nosetval.sql" 3 "exactly one setval of public.sync_seq (found 0)" "no sync_seq setval -> refused"

# the real exports, when the CLI and the local stack are at hand
cli() { (cd "$HERE/../.." && env $(env | sed -n 's/^\(SUPABASE_[A-Za-z0-9_]*\)=.*/-u \1/p') supabase db dump --local "$@") >/dev/null 2>&1; }
if command -v supabase >/dev/null 2>&1 && "${PSQL:-/opt/homebrew/opt/libpq/bin/psql}" "$DB" -At -c "select 1" >/dev/null 2>&1; then
  if cli --data-only -f "$TMP/cli_default.sql"; then
    shape R19 "$TMP/cli_default.sql" 3 "only COPY format is accepted" "supabase db dump --data-only (INSERT format) -> refused as 'only COPY format'"
  else rec R19 INVALID "supabase db dump --data-only -> refused as 'only COPY format'" "the CLI could not produce the dump"; fi
  if cli --data-only --use-copy -f "$TMP/cli_copy.sql"; then
    shape R20 "$TMP/cli_copy.sql" 3 "outside the public schema" "supabase db dump --data-only --use-copy (whole database, auth.* included) -> refused with the R6 hint"
  else rec R20 INVALID "supabase db dump --data-only --use-copy -> refused" "the CLI could not produce the dump"; fi
  if cli --data-only --use-copy -s public -f "$TMP/cli_public.sql"; then
    shape R21 "$TMP/cli_public.sql" 3 "outside the synced set" "supabase db dump --data-only --use-copy -s public (every public table: api_keys, snapshots, …) -> refused with the R6 hint"
  else rec R21 INVALID "supabase db dump --data-only --use-copy -s public -> refused" "the CLI could not produce the dump"; fi
  if "$PG_DUMP" --data-only --dbname="$DB" -t public.events -t public.event_logs -t public.event_feedback -t public.todo_lists -t public.event_types -t public.skill_insights -t public.user_settings -t public.agent_preferences -t public.agent_conversations -t public.sync_seq -t public.sync_epoch -t public.sync_versions -f "$TMP/r6.sql" 2>/dev/null; then
    shape R22 "$TMP/r6.sql" 2 "$ACCEPT" "the R6 export command (pg_dump --data-only -t the twelve relations) passes the parser"
  else rec R22 INVALID "the R6 export command passes the parser" "pg_dump could not produce the dump"; fi
else
  rec R19 INVALID "the real CLI exports" "supabase CLI not on PATH or the local stack does not answer; R19–R22 not run"
fi

echo
if [[ $fails -gt 0 || $invalid -gt 0 ]]; then echo "FAILED checks: $fails INVALID checks: $invalid"; exit 1; fi
echo "all restore parser checks passed"
