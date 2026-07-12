# Calendar Page — State-Interaction Map

> **Draft v3** — first cut for issue [#73]. The goal is to make the *implicit*
> coupling between PageView's ~80 `@State` flags *visible* enough that the next
> cross-midnight / boundary-extension PR reviewer can see what a one-line change
> actually touches.
>
> This is the artifact the #53/#55/#56/#58/#59 chain was missing.
>
> **Changelog**
>
> *v0 → v1:* carved C1a "Cross-day follow settle" out of C1; renamed the 0.6s
> magic number to `crossDayFollowSettleWindow`; resolved the test-seam question
> (helper XCTest + 2 UI tests deferred to dogfood).
>
> *v1 → v2 (adversarial review):* reframed the C1 / C1a carve to code-path
> locality (lifecycle was a useful intuition, not the criterion); recorded a
> C1a → C2 fade-progress write edge (rebounce animator block writes C2's fade);
> fixed `RangeMode` (v1 invented a `CalendarRangeMode` type that doesn't exist);
> corrected §2c onChange-site line numbers; tightened `AbandonedFadeInputs`;
> noted helper visibility + `@testable` requirement.
>
> *v2 → v3 (second adversarial review):* **dropped `fadeInBoundaryExtension`
> (line 2643) from C1a — it's C2-internal, called from
> `handleTimelineBoundaryExtensionStateChange` (line 2781). v2 overcorrected
> by attributing it to C1a's rebounce block; the only true C1a → C2 fade-write
> edge is the rebounce animator block at lines 4318–94.** Tightened §1a's
> "Written by" cell for fade-progress (line-precise C2 write sites);
> disambiguated §4d helpers as nested-private inside §4a's helper; collapsed
> §3 graph's three arrowheads (C1a → C2) to a labeled pair; clarified §3
> invariant 1's "C5 ∧ C5" with role subscripts.

## Scope

`Done/Views/Calendar/CalendarPageView.swift` (4941 LOC). Sister doc:
[`docs/calayer-rewrite/05-state-dataflow-contract.md`](./calayer-rewrite/05-state-dataflow-contract.md)
maps the SwiftUI↔CALayer **boundary**; this doc maps **PageView-internal**
state coupling that lives above that boundary.

## How to read this doc

If you are about to touch a handler in PageView and want to know what else it
reads, jump to §2 and look up the handler name. If you are about to touch a
`@State` flag and want to know who reads it, jump to §1 and follow the
`Touched-by` column. If you are wondering why three onChange observers all call
the same function, see §3.

---

## 1. State, grouped by concern

The 80-ish `@State` declarations in `CalendarPageView` (lines 1031–1193) split
into **9 concerns + 1 sub-concern**. Most concerns are internally cohesive; the
**6 starred** concerns are the ones that interact across the cross-midnight /
boundary-extension codepaths and are the load-bearing surface for this doc.

| # | Concern | Written by | Owns | Decl. lines |
|---|---|---|---|---|
| C1★ | Drag (per-frame + post-gesture rebounce) | EventBlock gestures (per-frame `timelineDragState`); rebounce animators driven by abandon-release **and** by follow-event commit | `timelineDragState`, `crossDayRebounceAnimator`, `sameDayRebounceAnimator` | 1099, 1127, 1133 |
| C1a★ | Follow-event commit settling state | the follow-event commit code path (`CalendarPageView.swift:4234-4398`) | `crossDayFollowEventAt`, `pendingFollowEventDayOverride`, `suppressDayColumnHorizontalAnimation` | 1140, 1155, 1147 |
| C2★ | Boundary extension | C2 handlers (`fadeInBoundaryExtension` at 2649-50/2655-56, `refreshAbandonedExtension` at 2722/2737, `handleStateChange`'s re-engage branch at 2788-89, `apply/clearTimelineBoundaryExtensionState`); fade-progress *also* written by C1a's rebounce animator block (4318-94) | `timelineBoundaryExtensionState`, `timelineRawBoundaryExtensionState`, `boundaryExtensionVisualYOffset`, `timelineLeadingFadeProgress`, `timelineTrailingFadeProgress`, `pendingBoundaryExtensionScrollTask`, `boundaryExtensionScrollAnimator` | 1101, 1102, 1056, 1164, 1165, 1116, 1121 |
| C3★ | Range mode (host side) | range-mode picker UI; dayRange via expansion helpers | `calendarState.rangeMode` (NOT @State here — `@Observable` on `calendarState`), `dayRange` | 1045 + external |
| C4★ | Midnight shift | `handleClockMaybeChanged`; drained by `tryApplyPendingMidnightShift` | `midnightLastKnownStartOfDay`, `midnightPendingDaysCrossed` | 1189, 1193 |
| C5★ | Resize / live-interrupt gates | resize-grace begin/cancel; interrupt session begin/end | `resizeGraceState`, `resizeGraceOccurrenceContext`, `resizeGraceFadeTask`, `resizeGraceExpiryTask`, `liveInterruptSession` | 1082–1085, 1075 |
| C6 | Routing / sheets | flow-driven | `selectedEventDetailRoute`, `selectedEventChatOccurrence`, `selectedEventForEdit`, `isShowingDatePicker`, `isShowingAgent`, `isShowingSearch`, `isShowingShare`, `eventShareContext`, `pendingInterruptComposer`, `pendingCreateTimeRange`, `pendingRecurrenceEdit`, `recurrenceEditScope`, `showRecurrenceScopeDialog`, `showLongPressDeleteConfirm` | 1057–1077 |
| C7 | Long-press / floating menu | press-driven | `floatingMenuAnchor`, `floatingMenuOccurrence`, `floatingMenuInteractive`, `floatingMenuActivationTask`, `floatingMenuActivationToken` | 1060–1064 |
| C8 | Scroll viewport | scroll observers | `timelineVerticalScrollY`, `timelineScrollViewportHeight`, `verticalScrollPosition`, `isVerticallyScrolling`, `timelineVisibleDayFrameGlobal`, `lastTimelineTopOverlayInset`, `lastDynamicPinchMinInputs`, `timelineCollapseDim` | 1093, 1103, 1100, 1114, 1115, 1108, 1109, 1170 |
| C9 | Caches / lifecycle | data-driven (store mutations, day-change, dayRange expansion) | `occurrencesCache`, `allDayOccurrencesCache`, `maxAllDayCountCache`, `progressiveCacheTask`, `hasAppearedOnce`, `needsScrollToNow`, `timerRefreshCancellable`, `capturedPageGeometry` | 1042–1044, 1171, 1097, 1098, 1079, 1179 |

> **Why split C1 → C1 + C1a? — code-path locality, not lifecycle.** The three
> C1a flags are written by a single code block: the follow-event commit code
> path (`CalendarPageView.swift:4234-4398`). The C1 rebounce animators are
> written by *two* paths — that same follow-event commit code AND the
> abandon-release rebounce path. So even though all of {C1 rebounce, C1a flags}
> are "post-gesture" lifecycle-wise (a useful intuition v1 leaned on), only the
> C1a flags are *code-path-co-local*. The split keeps C1a clean: every C1a
> flag → same writer block → same reader contract. If a future PR adds a new
> "post-follow-event settle" flag, the §1 table says where it goes.

> **Why 6 stars?** Each starred concern has at least one flag in the §1a
> cross-concern read table below. C6-C9 don't (they churn for different
> reasons: UX flows, perf) and are out of scope for this doc.

> **Note on C2 fade progress** (`timelineLeadingFadeProgress`,
> `timelineTrailingFadeProgress`): consumed downstream as prop-driven opacity
> by `TimelinePagerView` (CalendarPageView.swift:3269/3270) and from there by
> `TimeAxisLayerView` and `TimelineView` — pure SwiftUI prop pass-through, no
> back-channel write from those consumers. But the values **are written by a
> cross-concern actor**: C1a's rebounce animator block writes them at
> `CalendarPageView.swift:4318–94` (the follow-event settle path). That edge
> is the §1a fade-progress row + the §3 "C1a writes fade" edge — v0 and v1
> missed it; v2 overstated it (it incorrectly attributed C2's own
> `fadeInBoundaryExtension` to C1a); v3 has it precisely.

### 1a. Cross-concern reader: each ★-state at a glance

| State (concern) | Written by | Read by handlers across other concerns |
|---|---|---|
| `timelineDragState.dragOffset` (C1) | EventBlock gestures (UIKit side) | `refreshAbandonedExtension` (C2), `handleClockMaybeChanged`→`tryApplyPendingMidnightShift` (C4) |
| `timelineDragState.draggingEventID` (C1) | EventBlock gesture begin/end | `tryApplyPendingMidnightShift` gate (C4), `handleTimelineBoundaryExtensionStateChange`'s read of `crossDayFollowEventAt` window (C2) |
| `timelineDragState.draggingOriginalRange` (C1) | EventBlock begin | `refreshAbandonedExtension` core math (C2) |
| `crossDayFollowEventAt` (C1a) | follow-event commit code path (lines 4310, 4344) | `refreshAbandonedExtension` **settle-window guard** (C2; line 2673), `handleTimelineBoundaryExtensionStateChange`'s `followGuardActive` closure (C2; line 2762). Both reads are "settle is in progress — sit out", NOT "drag is in progress — sit out". |
| `timelineLeadingFadeProgress` / `timelineTrailingFadeProgress` (C2) | C2 itself: `refreshAbandonedExtension` (lines 2722, 2737), `fadeInBoundaryExtension` (lines 2649-50, 2655-56), `handleStateChange`'s re-engage branch (lines 2788-89), `applyTimelineBoundaryExtensionState` / `clearTimelineBoundaryExtensionState`. **Also by C1a's rebounce animator block** (lines 4318–94) — when the follow-event commit fires, the C1a path drives the fade directly during settle. | `refreshAbandonedExtension` self-coalescing reads (`if abs(diff) > 0.001`) + outbound to `TimelinePagerView` (lines 3269/3270 → `TimeAxisLayerView` opacity, `TimelineView` opacity). No back-channel write from consumers. |
| `timelineBoundaryExtensionState` (C2) | `applyTimelineBoundaryExtensionState`, `clearTimelineBoundaryExtensionState` | `refreshAbandonedExtension` (self, but also reads `.leadingHours`/`.trailingHours` for fade math), `handleTimelineBoundaryExtensionStateChange`'s `wasOpen` check, `onChange(rangeMode)` clear (C3) |
| `timelineRawBoundaryExtensionState` (C2) | `handleTimelineBoundaryExtensionStateChange` | `refreshAbandonedExtension` *intent gate* (C2 self-read, but conceptually a sub-flag) |
| `calendarState.rangeMode` (C3) | range-mode picker UI | `handleTimelineBoundaryExtensionStateChange` early-return guard (C2), many display sites in body |
| `dayRange` (C3) | `expandDayRangeForMonthContext`, `expandDayRangeToInclude`, `calendarExpandedDayRange` | `rebuildOccurrencesCacheIncremental` (C9), `tryApplyPendingMidnightShift`→`rebuildOccurrencesCache` (C4→C9) |
| `midnightPendingDaysCrossed` (C4) | `handleClockMaybeChanged` accumulate, `tryApplyPendingMidnightShift` zero | `tryApplyPendingMidnightShift` |
| `resizeGraceState` (C5) | `beginResizeGrace`, `cancelResizeGrace` | `tryApplyPendingMidnightShift` gate (C4), `onChange(rangeMode)` cancel (C3) |
| `liveInterruptSession` (C5) | interrupt session begin/end | `tryApplyPendingMidnightShift` gate (C4) |

> Read this table sideways: the rows where "Read by" lists **more than one
> other concern** are the rows the cross-midnight audit flagged. **Twelve
> flags** out of ~80 carry the cross-concern coupling (drag scratchpad
> counted as three rows for its sub-fields).
>
> `pendingFollowEventDayOverride` (C1a) and `suppressDayColumnHorizontalAnimation`
> (C1a) are NOT in this table — they're written by C1a's commit block and
> read only by display logic (the former) or as `TimelinePagerView` prop output
> (the latter). C1a-owned + downstream-only. (Distinct from the fade-progress
> row above, where C1a writes a flag *owned by C2* — that's the real
> cross-concern edge.)

---

## 2. Handlers that fuse concerns

Below: the three handlers #73 names, plus a fourth (`handleClockMaybeChanged`)
the audit reads as one logical step with `tryApplyPendingMidnightShift`.

### 2a. `refreshAbandonedExtension(topOverlayInset:)` — lines 2671–2744

**Touches:** C2 (read+write fade progress), C2 (read raw + retained extension state),
C1 (read original drag range, drag offset), **C1a (settle-window guard on
`crossDayFollowEventAt`)**, C8 (read scroll Y + viewport height + overlay inset).

**Reads (12):** `timelineBoundaryExtensionState`, `crossDayFollowEventAt`,
`timelineRawBoundaryExtensionState`, `timelineDragState.draggingOriginalRange`,
`calendarState.timelineHourHeight`, `timelineDragState.dragOffset`,
`timelineAllDayHeight` (env-derived), `timelineHeaderHeight`,
`timelineVerticalScrollY`, `timelineScrollViewportHeight`,
`timelineLeadingFadeProgress`, `timelineTrailingFadeProgress`.

**Writes (2):** `timelineLeadingFadeProgress`, `timelineTrailingFadeProgress`.

**Called from (3 sites):**
1. `handleTimelineBoundaryExtensionStateChange` line 2796 (state-leave branch).
2. `.onChange(of: timelineDragState.dragOffset)` line 3207 (every drag frame).
3. `.onChange(of: timelineVerticalScrollY)` line 3228 (every scroll tick).

**Why it's painful:** the inner math (stage1 / stage2 / combine) is pure — given
five scalars it returns two scalars — but the function reads 12 fields directly,
so a touch to any field's name forces a re-grep through 70 lines of dispersed
read sites. The pure inner math is the natural extraction (see §4a).

### 2b. `handleTimelineBoundaryExtensionStateChange(_:)` — lines 2746 → ~3000

**Touches:** C3 (rangeMode early-return), C2 (write raw + retained, apply
extension), **C1a (followGuardActive from `crossDayFollowEventAt`)**, C2 (fade
animations on re-engage), C2 (scroll-driven dismiss path).

**Called from (1 site):** `TimelinePagerView.onBoundaryExtensionStateChange`
callback — line 3292.

**Why it's painful:** opens the rangeMode-clear early-return branch, the
followGuard branch, the re-engage branch, AND the abandon-release rebounce
branch, all in one function. The first guard (`rangeMode != .day` → clear) is
itself a small predicate that lives elsewhere too (see §4c).

### 2c. `tryApplyPendingMidnightShift(reason:)` — lines 3728–3758

**Touches:** C4 (read+zero pending counter), C1 (gate on draggingEventID),
C5 (gate on resizeGraceState, liveInterruptSession), C3 (write selectedDayOffset),
C9 (rebuild caches).

**Called from (4 sites)** (citing the `.onChange` observer line, not the
call-inside-closure):
1. `handleClockMaybeChanged` line 3721 (every minute timer + day-change).
2. `.onChange(of: timelineDragState.draggingEventID)` line 1503.
3. `.onChange(of: resizeGraceState == nil)` line 1508.
4. `.onChange(of: liveInterruptSession == nil)` line 1513.

**Why it's painful:** the gate is three independent flags AND'd together; each
of the four call sites exists because one of the three gates may have just
cleared, and we want to retry. The retry pattern (defer + retry on each gate
clear) is what makes the four call sites feel duplicated. The gate predicate is
the natural extraction (see §4b).

### 2d. `handleClockMaybeChanged(reason:)` — lines 3704–3722

Co-trigger with `tryApplyPendingMidnightShift`. Always followed by a call to it.

**Reads (1):** `midnightLastKnownStartOfDay`. **Writes (2):**
`midnightLastKnownStartOfDay`, `midnightPendingDaysCrossed`.

Self-contained relative to other concerns — it only writes to C4. Listed here
for symmetry with §2c.

---

## 3. State-interaction graph

The relationships the audit cared about. Solid = direct read; dashed = retry/
deferral relationship; double-line = mutual coupling.

```
                                     ┌────────────────────────────────┐
                                     │ C3  rangeMode / dayRange       │
                                     └────────────────────────────────┘
                                              │              │
                                              │ .day-only    │ on expand
                                              ▼              ▼
        ┌──────────────────────┐    ┌──────────────────────┐    ┌─────────────────────┐
        │ C1  Drag             │═══▶│ C2  boundaryExtension│    │ C9  occurrencesCache │
        │   dragOffset         │    │   raw / retained     │    │  (rebuild target)    │
        │   draggingEventID    │    │   leading/trailing   │    └─────────────────────┘
        │   draggingOrigRange  │    │   fade progress      │              ▲
        │   rebounce animators │    └──────────────────────┘              │ rebuild after shift
        └──────────────────────┘                ▲                         │
                  │                             │                         │
                  │                guard (settle│                         │
                  │                window 2673  │                         │
                  │                + 2762)      │                         │
                  │                + writes fade│                         │
                  │                during settle│                         │
                  │                (4318-94)    │                         │
                  │              ┌──────────────────────┐                 │
                  │              │ C1a Follow-event    │                  │
                  │              │ commit settling     │                  │
                  │              │   crossDayFollowEventAt│               │
                  │              │   pendingFollowDayOver │               │
                  │              │   suppressDayColAnim   │               │
                  │              └──────────────────────┘                 │
                  │ retry-trigger                                         │
                  ▼                                                       │
        ┌──────────────────────┐                       ┌──────────────────────┐
        │ C4  midnight pending │───────────────────────│ C5  resizeGrace /    │
        │   counter            │  gate (all 3 clear)   │     liveInterrupt    │
        └──────────────────────┘                       └──────────────────────┘
                  ▲
                  │ every tick / day-change
                  │
        ┌──────────────────────┐
        │ wall clock (timer)   │
        └──────────────────────┘
```

**Invariants the chain enforces (informal):**

1. Midnight shift waits for all of {drag, resizeGrace, liveInterrupt} to clear,
   then applies. (C4 ← C1 ∧ C5[resize] ∧ C5[interrupt].)
2. Boundary extension is gated to `.day` rangeMode; any switch off `.day`
   collapses it. (C2 ← C3.)
3. Abandon fade reads the live drag offset to position the band; without an
   active drag (no `draggingOriginalRange`), the function early-returns.
   (C2 ← C1.)
4. **Follow-event commit opens a `crossDayFollowSettleWindow` (0.6s) during
   which abandoned-extension refreshes and state-change re-applies in C2 are
   suppressed**, AND the C1a rebounce animator block (lines 4318–94) **writes
   C2's fade progress directly** during the settle. The post-commit mirror
   should not flash through the dismiss path. (C2 ← C1a, both as guard read
   and as direct write.)

> If a future PR breaks any of these four invariants, the integration tests in
> §5 should catch it (modulo the dogfood gate — see §5).

---

## 4. Extraction candidates (the §A deliverable in #73)

**Helper visibility convention:** declare top-level extracted helpers as
`internal` (default), and access them from `DoneTests/CalendarPageHandlerHelpersTests.swift`
via `@testable import Done`. Avoid `private` at the top level so the test file
doesn't need same-source-file colocation. *Nested* helpers (e.g. §4d) stay
`private` to their enclosing helper — see the §4d note.

### 4a. `computeAbandonedFadeCurves(...)` → `(leading: CGFloat, trailing: CGFloat)`

Pull the pure math out of `refreshAbandonedExtension`. Signature draft:

```swift
struct AbandonedFadeInputs {
    let rawState: TimelineBoundaryExtensionState
    let appliedState: TimelineBoundaryExtensionState
    let dragOriginalRange: Event.TimeRange
    let dragOffsetY: CGFloat
    let hourHeight: CGFloat
    let extensionOriginY: CGFloat   // = topOverlayInset + allDayHeight + headerHeight
    let scrollY: CGFloat
    let viewportHeight: CGFloat
    let baseVisibleHours: Int        // calendarTimelineBaseVisibleHours
}

struct AbandonedFadeCurves {
    let leading: CGFloat?    // nil = leave current value untouched
    let trailing: CGFloat?
}

func computeAbandonedFadeCurves(_ input: AbandonedFadeInputs) -> AbandonedFadeCurves
```

The host call site shrinks to: build inputs → call helper → write progress
states under a `Transaction(disablesAnimations: true)`. The host writes the
two `@State` fields directly (still PageView-owned); the helper has no SwiftUI
deps so it unit-tests trivially.

The current per-field "if abs(diff) > 0.001" gate stays at the call site
(it's a write-coalescing concern, not part of the curve math).

> v1 had `topOverlayInset`/`timelineAllDayHeight`/`timelineHeaderHeight` as
> three separate inputs. In `refreshAbandonedExtension` they only flow into a
> single sum (`extensionOriginY` at line 2706). One input is right.

### 4b. `shouldAllowMidnightShift(...)` → `Bool`

```swift
func shouldAllowMidnightShift(
    draggingEventID: UUID?,
    resizeGrace: CalendarResizeGraceState?,
    liveInterrupt: CalendarInterruptLiveSession?
) -> Bool {
    draggingEventID == nil
        && resizeGrace == nil
        && liveInterrupt == nil
}
```

Trivial as a predicate, but pulling it into a name lets the three onChange
retry sites all reference *the same name*, instead of each spelling the AND
out. The next person who adds a fourth gate (e.g. a long-press menu)
edits one predicate, not four call sites.

### 4c. `boundaryExtensionShouldClearOnRangeModeChange(...)` → `Bool`

```swift
func boundaryExtensionShouldClearOnRangeModeChange(
    newMode: RangeMode,
    currentExtensionState: TimelineBoundaryExtensionState
) -> Bool {
    newMode != .day && currentExtensionState != .none
}
```

Two call sites today: line 2749 inside `handleTimelineBoundaryExtensionStateChange`
(reactive — when the callback fires and we're not in day), and line 1480
inside `.onChange(of: rangeMode)` (proactive — when day changes to non-day).
The current logic at those two sites is *almost* the same predicate but spelled
differently, which makes it easy to drift if someone adds a `.stream` rangeMode
behavior later.

> Type name is `RangeMode` (declared in `CalendarPageState.swift:28`), NOT
> `CalendarRangeMode`. v1 invented the wrong name.

### 4d. Name the abandon-fade two-stage math

Stage 1 (`stage1`) and stage 2 (the `s2 = max(0, min(1, 1 - d / bandHeight))`
inline expression) are both named formulas in the inline comments but have no
function name. Suggestion: **nest these inside `computeAbandonedFadeCurves`
(§4a)** rather than expose at file scope — they're implementation details of
the fade-curve math, not predicates the test suite needs to reach. Because
they nest, they stay `private`; the §4 introduction's "avoid private" applies
to *top-level* helpers only.

```swift
func computeAbandonedFadeCurves(_ input: AbandonedFadeInputs) -> AbandonedFadeCurves {
    func fingerDrivenStage1Fade(distHours: Double, ...) -> CGFloat { ... }
    func positionDrivenStage2Fade(boundaryY: CGFloat, viewportEdge: CGFloat,
                                  bandHeight: CGFloat) -> CGFloat { ... }
    func combineFades(_ s1: CGFloat, _ s2: CGFloat) -> CGFloat { ... }
    // ... use the three ...
}
```

The combine function in particular (`1 - (1-s1)*(1-s2)`) is the
multiply-complement opacity combine and shows up nowhere else in the codebase
(searched). Worth a name even at nested scope.

### 4e. Pull `crossDayFollowSettleWindow` to a named constant

Today the 0.6s settle window appears as a bare literal in two read sites:
`refreshAbandonedExtension` line 2673 and `handleTimelineBoundaryExtensionStateChange`'s
`followGuardActive` closure line 2762. Both check
`Date().timeIntervalSince(stamp) < 0.6`. (NB: the `0.6` at line 2694 is
`stage1MaxFade` for the abandon-fade curve — same number, different concept,
do NOT collapse.) Suggestion:

```swift
internal let crossDayFollowSettleWindow: TimeInterval = 0.6
```

A single declaration at file scope, two read sites. Next time someone tunes
the rebounce animator duration (currently 1.1s), they have one place to look
for "what settle window does the rest of the chain assume?".

---

## 5. Integration test targets (the §C deliverable in #73)

For each invariant in §3, a corresponding behavior-level test. The Q4
test-seam decision: **pure XCTest where the test is really about a predicate
extracted in §4; UI test deferred to dogfood for the two end-to-end gesture
flows.** Rationale: this project has no existing UI test infrastructure;
introducing it just for two tests is its own scope.

Helpers are `internal` (per §4 convention); tests reach them via
`@testable import Done`.

| Test | Kind | Sets up | Asserts |
|---|---|---|---|
| `testDragAcrossMidnightTriggersBoundaryExtension` | **UI test — deferred to dogfood gate** | Drag event from 23:00→01:00 next day, single-day range mode | `timelineBoundaryExtensionState.trailingHours > 0` while drag active |
| `testRangeModeChangeClearsBoundaryExtension` | **Pure XCTest** on §4c predicate | Construct `TimelineBoundaryExtensionState` open + `RangeMode = .threeDay` | `boundaryExtensionShouldClearOnRangeModeChange(newMode: .threeDay, currentExtensionState: open) == true` |
| `testMidnightShiftBlockedDuringResizeGrace` | **Pure XCTest** on §4b predicate | resizeGrace = mock state | `shouldAllowMidnightShift(.., resizeGrace: mock, ..) == false` |
| `testInterruptSessionBlocksMidnightShift` | **Pure XCTest** on §4b predicate | liveInterrupt = mock session | `shouldAllowMidnightShift(.., liveInterrupt: mock) == false` |
| `testMidnightShiftFiresAfterDragEnd` | **UI test — deferred to dogfood gate** | Drag begin → set pending midnight crossed → drag end | `selectedDayOffset` shifts on the onChange tick |

Constructibility verified for the three Pure XCTest rows: `RangeMode`,
`TimelineBoundaryExtensionState`, `CalendarResizeGraceState`, and
`CalendarInterruptLiveSession` are all memberwise-constructible value types
on the current `king-of-rubbish-bin`.

The pure helpers (§4a/b/c/d/e) also get unit tests — most are mechanical given
the signatures. They belong in `DoneTests/CalendarPageHandlerHelpersTests.swift`.

### 5a. The dogfood gate

The two UI-deferred tests above MUST be exercised manually before any
extraction-PR lands. Dogfood checklist for the extractor:

1. Single-day, drag an event from 23:00 across midnight into the next day,
   release. The trailing extension band must open, then collapse smoothly
   without a flash (this is the #55 follow-up the chain ate twice).
2. While a midnight tick is pending (easiest repro: simulator wall-clock
   tick by setting device time), drag any event. The selectedDayOffset
   shift must NOT apply until the drag ends.
3. Same as 2 but for resize grace and live-interrupt sessions.

If any extraction-PR cannot pass the dogfood gate, the helper signature is
wrong (almost certainly losing an input that the original handler was
implicitly reading).

---

## 6. Resolved questions (audit trail v0 → v3)

These were `§6 Open questions` in v0; resolved across v1 + v2 + v3 revisions.

1. **C8 reads C2's fade progress?** — **Resolved with nuance.** Greps confirmed
   every fade-progress *read* is intra-C2 coalescing or downstream SwiftUI
   prop pass-through (`TimelinePagerView` → `TimeAxisLayerView` / `TimelineView`
   opacity). No back-channel read from those consumers. BUT the *write* side
   was wrong in v0/v1: C1a's rebounce animator block writes the fade values
   during settle (`CalendarPageView.swift:4318–94`). That's a real C1a → C2
   write edge captured in §1a + §3 + invariant 4. v2 went too far in the other
   direction and also attributed `fadeInBoundaryExtension` (line 2643) to C1a;
   v3 corrects that — `fadeInBoundaryExtension` is C2-internal, called from
   `handleTimelineBoundaryExtensionStateChange` (line 2781). So the doc has
   gone through "no edge" → "edge + over-attribution" → "edge, properly scoped".

2. **`crossDayFollowEventAt` 0.6s magic?** — **Resolved: name it.** v0's claim
   that 0.6s appears "once in the dispatch chain" was incorrect — it appears in
   exactly two read sites (`refreshAbandonedExtension` line 2673 + `followGuardActive`
   closure line 2762). The `0.6` at line 2694 is `stage1MaxFade`, a coincidence
   of value, NOT the same constant. Promote to `crossDayFollowSettleWindow`.
   See §4e.

3. **`pendingFollowEventDayOverride` and `suppressDayColumnHorizontalAnimation`
   sub-concern?** — **Resolved: split C1a out, criterion is code-path
   locality.** v1 leaned on a "lifecycle" argument (per-frame vs one-shot)
   that didn't hold up — the rebounce animators are also post-gesture but
   stay in C1. The honest criterion is *which writer block touches the flag*:
   the three C1a flags are all written by `CalendarPageView.swift:4234-4398`
   (the follow-event commit code path); rebounce animators are written by
   that path AND by the abandon-release path, so they're not code-path-co-local
   with C1a. Lifecycle is a useful intuition but secondary.

4. **Test seam?** — **Resolved: hybrid.** 3 of 5 §5 tests collapse to pure
   XCTest against the §4 predicates once those helpers exist. 2 of 5 are
   end-to-end gesture flows that genuinely need a UI test harness; we defer
   those to a dogfood gate (§5a) rather than introduce a UI test
   infrastructure that this codebase doesn't otherwise use. Critically, **no
   move to extract handlers into an `@Observable` coordinator class** —
   that's the #70 trap.

---

## 7. Sequencing & non-goals

* This doc is **prescriptive about extraction shape, descriptive about state
  ownership**. State stays where it is. The §4 helpers are pure functions
  that PageView calls; PageView still owns the `@State`.
* Splitting `CalendarPageView.swift` into multiple files is **out of scope**
  here — it's the obvious follow-up once the helpers exist, but mixing it
  with the helper-extraction PR will hide whether the behavior actually
  changed.
* The integration tests in §5 are the **gate** — extraction PRs without
  passing tests on the cross-midnight chain are landing blind. The user has
  been bitten enough times by this chain (#53/#55/#56/#58/#59 each touched
  it) that the test investment pays. The 2 UI-deferred tests pay their
  insurance through dogfood (§5a), not CI.
* The C1/C1a split is **observational** — no code moves between concerns.
  The flags' decl. lines stay where they are; the sub-concern is purely a
  documentation cut so §3's graph reads correctly.

## Refs

- Issue [#73] — the work this doc anchors.
- Issue [#70] (closed) — the state-split proposal this doc explicitly
  replaces. The audit reasoning lives in #73's "Background" section.
- [`docs/calayer-rewrite/05-state-dataflow-contract.md`](./calayer-rewrite/05-state-dataflow-contract.md) — the
  SwiftUI↔CALayer boundary contract. Read together with this doc, you get a
  full picture of state ownership above and below the timeline boundary.
- Memory: `feedback_bug_fix_methodology.md`, `project_calayer_timeline_render_paths.md`.

[#70]: https://github.com/MaySong-Mei/Done/issues/70
[#73]: https://github.com/MaySong-Mei/Done/issues/73
