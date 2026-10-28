#!/usr/bin/env bash
# Telemetry chassis bench (migrations 016 + 017, gh#273) on the LOCAL stack:
#   1. supabase start (if not running), then supabase db reset --local, which
#      applies every migration 001–017 to the local database;
#   2. the key registry rows (telemetry/key_registry_load.sql, generated from
#      key_registry.json; the runner refuses to continue when the SQL is stale);
#   3. sync_feed_checks.sql — the 015 bench, to show 016 did not turn it red;
#   4. telemetry_checks.sql — the 016 + 017 bench (T1 … T33);
#   5. telemetry_wire_conformance.sql — QA's client-row bench, when present.
# This machine has no host psql, so psql runs INSIDE the supabase_db container:
# supabase/{migrations,tests,telemetry,ops} and verification/telemetry-fixtures.json
# are copied to /tmp/bench in the repo's own layout (the benches read their
# fixtures by paths relative to tests/), and psql connects over the container's
# own address (scram), which is what the benches' dblink sessions need (a
# unix-socket or loopback connection is trust-authenticated and dblink refuses
# it for a non-superuser).
# Never points at a hosted project: only `supabase start` / `supabase db reset
# --local` / `docker exec` are used; no link, no push, no --linked.
# Exits non-zero when any part failed. LOG_DIR= keeps the full psql outputs.
#   RESET=0   skip the db reset (reuse the running database; the benches clean
#             up after themselves, the registry upsert is idempotent)
#   SKIP_SYNC=1  skip the 015 bench
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SUPA=$(cd "$HERE/.." && pwd)
PROJ=$(cd "$SUPA/.." && pwd)
ROOT=$(cd "$PROJ/.." && pwd)
BENCH=/tmp/bench
LOG_DIR=${LOG_DIR:-$(mktemp -d)}
RESET=${RESET:-1}
SKIP_SYNC=${SKIP_SYNC:-0}
EXCLUDE=${SUPABASE_EXCLUDE:-studio,imgproxy,mailpit,logflare,vector,edge-runtime,supavisor}
mkdir -p "$LOG_DIR"

status=()
part() { # name, command...
  local name=$1; shift
  echo; echo "################ $name"
  "$@"; local rc=$?
  status+=("$name exit=$rc")
  return 0
}
die() { echo "run_checks: $*" >&2; exit 2; }

command -v docker >/dev/null || die "docker CLI not found"
command -v supabase >/dev/null || die "supabase CLI not found"
curl -s -m 5 --unix-socket "${DOCKER_SOCK:-$HOME/.docker/run/docker.sock}" http://localhost/_ping 2>/dev/null | grep -q OK \
  || docker info >/dev/null 2>&1 || die "the Docker engine is not answering (start Docker Desktop first)"

cd "$PROJ" || die "cannot cd to $PROJ"

# 1. stack up (local), database reset to the migrations
if ! supabase status >/dev/null 2>&1; then
  echo "starting the local stack (excluding: $EXCLUDE)"
  supabase start -x "$EXCLUDE" || die "supabase start failed"
fi
supabase status 2>/dev/null | grep -qE '127\.0\.0\.1|localhost' || die "supabase status does not show a local stack; refusing"
if [[ $RESET == 1 ]]; then
  echo "resetting the LOCAL database to the migrations"
  supabase db reset --local || die "supabase db reset --local failed (a migration did not apply; see above)"
fi

DB=$(docker ps --filter 'name=supabase_db_' --format '{{.Names}}' | head -n 1)
[[ -n $DB ]] || die "no running container named supabase_db_*"
echo "db container: $DB"

# 2. registry SQL current? then copy the bench into the container
python3 -I "$SUPA/telemetry/gen_key_registry_sql.py" --check || die "telemetry/key_registry_load.sql is stale: run python3 -I telemetry/gen_key_registry_sql.py"
docker exec "$DB" sh -c "rm -rf $BENCH && mkdir -p $BENCH/done-mcp/supabase $BENCH/verification" || die "cannot prepare $BENCH in $DB"
for d in migrations tests telemetry ops; do
  docker cp "$SUPA/$d" "$DB:$BENCH/done-mcp/supabase/" || die "docker cp $d failed"
done
docker cp "$ROOT/verification/telemetry-fixtures.json" "$DB:$BENCH/verification/" || die "docker cp verification/telemetry-fixtures.json failed"

# psql inside the container, cwd tests/, over the container's own address
in_db_psql() {
  docker exec -i -e PGPASSWORD=postgres -w "$BENCH/done-mcp/supabase/tests" "$DB" sh -c '
    ip=$(hostname -i 2>/dev/null | cut -d" " -f1)
    [ -n "$ip" ] || ip=$(awk "END{print \$1}" /etc/hosts)
    exec psql -h "$ip" -p 5432 -U postgres -d postgres -v ON_ERROR_STOP=1 "$@"' sh "$@"
}

part "key registry load" in_db_psql -q -f ../telemetry/key_registry_load.sql

# a bench part: full output to LOG_DIR, the verdict table to the terminal
bench() { # name file
  local name=$1 file=$2 log="$LOG_DIR/$1.log" rc
  in_db_psql -f "$file" >"$log" 2>&1; rc=$?
  if grep -q '=== results' "$log"; then
    sed -n '/=== results/,$p' "$log"
  else
    echo "no results table in $log (psql exit=$rc); last lines:"; tail -n 20 "$log"
  fi
  echo "($name psql exit=$rc; full log: $log)"
  return $rc
}
if [[ $SKIP_SYNC != 1 ]]; then
  part "sync_feed_checks.sql (015 bench, must stay green)" bench sync_feed_checks sync_feed_checks.sql
fi
part "telemetry_checks.sql (016 + 017 bench)" bench telemetry_checks telemetry_checks.sql
if [[ -f $HERE/telemetry_wire_conformance.sql ]]; then
  part "telemetry_wire_conformance.sql (QA wire bench)" bench telemetry_wire_conformance telemetry_wire_conformance.sql
fi

docker exec "$DB" rm -rf "$BENCH" >/dev/null 2>&1

echo; echo "################ summary"
bad=0
for s in "${status[@]}"; do echo "$s"; [[ $s == *"exit=0" ]] || bad=1; done
echo "logs: $LOG_DIR"
exit $bad
