#!/usr/bin/env bash
# Dual-project verification gate (DoneMac plan, section B).
# 1) iOS compiles  2) Mac compiles  3) shared-semantics tests on Mac
# 4) semantic build settings identical  5) no service_role key in Mac-linked files
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
dd="${VERIFY_BOTH_DERIVED_DATA:-/tmp/dd-verify-both}"

echo "== 1/5 iOS build =="
xcodebuild -project "$root/Done.xcodeproj" -scheme Done \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$dd/ios" CODE_SIGNING_ALLOWED=NO build -quiet

echo "== 2/5 Mac build =="
xcodebuild -project "$root/DoneMac/DoneMac.xcodeproj" -scheme DoneMac \
  -destination 'platform=macOS' \
  -derivedDataPath "$dd/mac" CODE_SIGNING_ALLOWED=NO build -quiet

echo "== 3/5 shared-semantics tests on Mac =="
# Ad-hoc signing: the mac bundle id has no provisioning profile, and none is
# needed to run unit tests. Parallel testing stays OFF: multiple runner
# processes share one DiagnosticTrail file and interleave sessions
# (DiagnosticTrailTests flakes under parallel workers — reproduced 2026-09-09).
xcodebuild -project "$root/DoneMac/DoneMac.xcodeproj" -scheme DoneMac \
  -destination 'platform=macOS' \
  -derivedDataPath "$dd/mac" test -quiet \
  -parallel-testing-enabled NO \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO \
  PROVISIONING_PROFILE_SPECIFIER="" CODE_SIGN_ENTITLEMENTS=""

echo "== 4/5 semantic build-settings parity =="
keys=(SWIFT_VERSION SWIFT_DEFAULT_ACTOR_ISOLATION SWIFT_APPROACHABLE_CONCURRENCY SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY)
for key in "${keys[@]}"; do
  ios_vals=$(grep -o "${key} = [^;]*" "$root/Done.xcodeproj/project.pbxproj" | sort -u)
  mac_vals=$(grep -o "${key} = [^;]*" "$root/DoneMac/DoneMac.xcodeproj/project.pbxproj" | sort -u)
  if [ -n "$ios_vals" ] && [ "$ios_vals" != "$mac_vals" ]; then
    echo "SETTINGS DIVERGENCE on $key:" >&2
    echo "  iOS: $ios_vals" >&2
    echo "  Mac: $mac_vals" >&2
    exit 1
  fi
done
echo "   parity ok"

echo "== 5/5 key hygiene (no service_role JWT in Mac-linked sources) =="
# The known service_role literal's stable prefix (see SupabaseCore.swift TODO,
# issue #28 Stage 3). Any Mac-linked file carrying a JWT whose payload decodes
# to service_role must fail the gate once rotation is done; until rotation,
# only SupabaseCore.swift is allowed to hold it.
mac_files=$(grep -o 'path = "\.\./[^"]*"' "$root/DoneMac/DoneMac.xcodeproj/project.pbxproj" | sed 's|path = "\.\./||; s|"$||' | sort -u)
offenders=""
while IFS= read -r f; do
  [ -f "$root/$f" ] || continue
  case "$f" in Done/Services/Sync/SupabaseCore.swift) continue ;; esac
  if grep -q 'InNlcnZpY2Vfcm9sZSI' "$root/$f"; then
    offenders="$offenders $f"
  fi
done <<< "$mac_files"
if [ -n "$offenders" ]; then
  echo "SERVICE_ROLE KEY found outside SupabaseCore.swift:$offenders" >&2
  exit 1
fi
echo "   hygiene ok"

echo "== verify-both: ALL GREEN =="
