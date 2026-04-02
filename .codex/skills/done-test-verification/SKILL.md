---
name: done-test-verification
description: Project-specific Xcode verification playbook for the Done app. Use when validating code changes in this repo and you want the fastest reliable sequence: generic iOS build first, then narrow simulator tests with reused package resolution and derived data, and only then broader suites.
---

# Done Test Verification

## Goal

Validate changes with a cheap funnel:

1. generic build for compile/package sanity
2. narrow simulator tests for the touched behavior
3. broader regression only when justified

Assume the current directory is the repo root.

## Default Order

1. Run a generic iOS build first. This catches compile errors quickly and resolves packages once without waiting on Simulator:

```bash
HOME=/tmp/codex-home-analysis \
CFFIXED_USER_HOME=/tmp/codex-home-analysis \
CLANG_MODULE_CACHE_PATH=/tmp/clang-module-cache-analysis \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/swiftpm-module-cache-analysis \
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -project Done.xcodeproj -scheme Done \
  -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/DoneDerivedData-analysis \
  CODE_SIGNING_ALLOWED=NO build
```

2. Reuse that package resolution for simulator tests. Do not let each test run resolve packages again:

```bash
HOME=/tmp/codex-home \
CFFIXED_USER_HOME=/tmp/codex-home \
CLANG_MODULE_CACHE_PATH=/tmp/clang-module-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/swiftpm-module-cache \
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild test -project Done.xcodeproj -scheme Done \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.0' \
  -disableAutomaticPackageResolution \
  -clonedSourcePackagesDirPath /tmp/DoneDerivedData-analysis/SourcePackages \
  -derivedDataPath /tmp/DoneDerivedData-<topic> \
  -only-testing:DoneTests/<TestClass>/<testMethod>
```

If the simulator destination stops working, resolve a fresh one:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -project Done.xcodeproj -scheme Done -showdestinations
```

3. Broaden only if the narrow run passes and the change actually warrants it:
- one method
- one class
- one tightly related suite
- full project or broad suites last

## Working Rules

- If step 1 fails, stop and fix the build before touching Simulator tests.
- Prefer `-only-testing` over class-wide or target-wide runs.
- Reuse `/tmp/DoneDerivedData-analysis/SourcePackages` after the generic build.
- Give each focused run its own `-derivedDataPath` so failures stay attributable.
- Use simulator tests only for behavior that needs runtime state. Pure compile or API-shape changes may only need step 1.
- If a targeted run fails in the intended area, fix that first instead of escalating to a broader suite.

## Known Noise

`CalendarDragLogicTests` is not a good first-line validator for small Calendar changes. A broad run has previously shown unrelated problems:

- `testAutoScrollDefaultsRespectConfiguredHorizontalAndVerticalInsets`
- crash near `testCreateInterruptTracksRelationLogAndStateTransitions`

Treat those as noise unless the current change touched that behavior. For narrow Calendar work, add or run targeted methods instead of using the whole class as the first check.

## Calendar Search Example

For Calendar search and note/log matching work, start with this targeted set after the generic build:

```bash
HOME=/tmp/codex-home \
CFFIXED_USER_HOME=/tmp/codex-home \
CLANG_MODULE_CACHE_PATH=/tmp/clang-module-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/swiftpm-module-cache \
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild test -project Done.xcodeproj -scheme Done \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.0' \
  -disableAutomaticPackageResolution \
  -clonedSourcePackagesDirPath /tmp/DoneDerivedData-analysis/SourcePackages \
  -derivedDataPath /tmp/DoneDerivedData-search \
  -only-testing:DoneTests/CalendarDragLogicTests/testSearchResultsIncludeEventFieldsAndOccurrenceLogMatches \
  -only-testing:DoneTests/CalendarDragLogicTests/testSearchResultsAggregateMultipleRecurringOccurrencesIntoSingleCard \
  -only-testing:DoneTests/CalendarDragLogicTests/testSearchResultsSortOccurrenceHitsAheadOfEventOnlyHits \
  -only-testing:DoneTests/CalendarDragLogicTests/testSearchResultsIgnoreOrphanLogRecords \
  -only-testing:DoneTests/CalendarDragLogicTests/testSearchResultsIncludeLegacyFeedbackNotes
```

## When To Broaden Anyway

- the user explicitly asks for a full suite
- the change touches shared drag/create infrastructure
- the change touches persistence or model code used across multiple features
- new coverage is intended to replace or retire older noisy tests

## Reporting

In the final response, separate these clearly:

- generic build result
- targeted test result
- broader suites intentionally skipped
- any remaining failures judged pre-existing or unrelated

Keep this skill current when a noisy suite becomes stable enough to promote earlier in the funnel.
