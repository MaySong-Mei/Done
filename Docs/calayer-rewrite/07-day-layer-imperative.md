# 07 — Day Layer Goes Imperative (Off the SwiftUI Tree)

Scope: take `DayLayerHostView` out from under SwiftUI's `UIViewRepresentable`
wrapper in single-day mode and drive it imperatively from a
`DayLayerCoordinator` class, sitting directly inside the UIScrollView content
view. Pair this with a **48h-constant coordinate model** (12h leading + 24h
day + 12h trailing) so band open/close mutates only `contentInset`, never
`contentSize`. Net effect: the SwiftUI-async ↔ UIKit-sync race class that PR
\#89 papered over with `applyCloseBandStateAtomicCoCommit` + leading-stale
compensation disappears at the renderer math level.

Reference: `project_calayer_timeline_rewrite` (the rewrite arc), specs 01–06
(visual / gesture / layout / animation / state contract / sequencing). This
doc extends 06 — it is the next concrete chunk of the per-day view replacement
after \#74 (axis), \#83 (mini-day), \#85 (focus event), \#86 (split), \#87
(cleanup), \#88 (boundary day hints).

---

## 1. Context & motivation

### 1a. Where this lands

We are halfway through 06's slice arc. Per-day visual fidelity (S0–S1), grid +
chrome (S2), pinch repaint (S3), gestures (S4), and most animations (S5) have
all shipped behind the existing flags. The remaining structural ports are:
the vertical scroll surface (issue \#57, PR \#89, `calendarUseUIScrollViewTimeline`),
the imperative day-layer host (this doc), and the SwiftUI horizontal pager
retirement (TBD follow-up). Today every `CalendarDayLayerView` is constructed
fresh on each SwiftUI body re-eval; `makeUIView` / `updateUIView` propagate
the Model into the persistent `DayLayerHostView` via `apply(model:callbacks:)`
(`CalendarDayLayerView.swift:125-134`).

### 1b. The bug class this closes

PR \#89 (the `calendarUseUIScrollViewTimeline` arc — `TimelineScrollHost`,
`TimelineScrollProxy.coCommit`, and `applyCloseBandStateAtomicCoCommit` at
`CalendarPageView.swift:1150`; the function landed via the PR's later commits
on this branch arc, verified live on main — re-grep `git log -- CalendarPageView.swift`
if in doubt) replaced the SwiftUI vertical `ScrollView` with a `UIScrollView`
so that band collapse could co-commit `contentSize` + `contentOffset` inside
a single `CATransaction`. It mostly
works. The residual leading-band flash (one frame of events shifted ~322 pt
down then snapping back, see `TimelineScrollHost.swift:159-193` and
`CalendarPageView.swift:1219-1257`) is not a bug in `coCommit` — it is a
**propagation race between two write surfaces**:

- `coCommit` writes `constraint.constant` + `scrollView.contentOffset`
  synchronously inside a CATransaction. The hosted content view's KVO on
  `contentOffset` fires immediately and the day-layer's
  `cullViewportIfChanged()` re-renders (`CalendarDayLayerView.swift:827-839`).
- SwiftUI's `timelineBoundaryExtensionState = .none` mutation also fires
  inside `coCommit`'s outer `withTransaction(disablesAnimations: true)`. But
  the resulting `.animation(_:value:)` plumbing, `body` re-eval, and
  `UIHostingController` subtree re-render arrive **on a later runloop tick**.
- For one frame the day-layer paints occurrences using the OLD
  `leadingExtendedHours` (its currently held Model still says band is open),
  but against the NEW compensated `contentOffset`. Every event renders at
  `yOffset + bandHours*hourHeight`. The user sees the flash.

The PR \#89 workaround is a `CATransform3DMakeTranslation` on
`hostContentView` that papers over the stale-Model frame, cleared one
display-link tick later (`TimelineScrollHost.swift:180-207`). It works for
the leading-close path but the same race class produces:

- \#57 leading flash (the original; partially papered).
- Cold-start scroll-to-0:00 race (host installs, KVO fires once with offset
  0, day-layer renders against unfinished Model).
- \#82 rebounce intermittent fire (multi-side bands close, only one side's
  Model has propagated when the second `coCommit` runs).
- \#80 now-indicator mask leak (mask geometry derived from SwiftUI Model
  desyncs from the layer's own band hours during the close frame).
- \#79 pinch crossfade smoothness (range-pinch frozen slot minutes propagates
  async; the layer's grid repaint and the SwiftUI label re-id flip don't
  agree about which slot density is current).
- \#65 `onVisibleTimelineFrameChange` race (frame callback fires off the
  layer's CALayer geometry, but the host reads
  `timelineVisibleDayFrameGlobal` for absorption — and absorption hit-tests
  also read SwiftUI-resolved drag state).

These all share the same shape: **two write surfaces with different
propagation latencies, both consumed by the same render frame.** The 48h
coordinate model + imperative host removes both halves of the race surface
in single-day mode. SwiftUI no longer owns the day-layer's Model; the
coordinator pushes deltas synchronously from the same `@onChange` /
delegate / gesture callback that triggered the change.

Likely also improved: \#37 first-interaction lag (no SwiftUI body eval to
push the first Model; the day-layer already exists at scene-load and the
coordinator just calls into it) and \#43 progressive frame drop (the
day-layer's host is no longer inside the SwiftUI invalidation tree, so
`occurrencesCache` rebuilds don't trigger redundant `updateUIView` thrash
through the page's body).

### 1c. Non-goals

See §8 for the canonical out-of-scope list (multi-day horizontal pager,
`allDaySection`, `extensionFadeMask`, and the already-shipped surface ports).
This section folds into §8 — kept as a heading anchor only.

---

## 2. The two core mechanisms

### 2A. 48h-constant single-day coordinate model

The current coordinate system is **band-state-conditional**: an event's
absolute Y inside the timeline is

```
absoluteY = headerHeight
          + allDayHeight
          + leadingExtendedHours*hourHeight        // 0, 6, or 12
          + (eventHourInDay)*hourHeight
```

so when the leading band opens or closes, every event's `absoluteY` shifts by
`Δleading*hourHeight`. `contentSize.height` shifts too. The atomic co-commit
exists precisely because those two must move together.

The new model is **band-state-INDEPENDENT** for events on day N, day N-1's
trailing 12 h, and day N+1's leading 12 h:

```
// 48h-constant Y math (single-day mode):
let baseY = headerHeight + allDayHeight + 12*hourHeight          // 0:00 of day N

func absoluteY(eventHour: Double, dayOffset: Int) -> CGFloat {
    switch dayOffset {
    case  0: return baseY + eventHour*hourHeight                  // day N: 0..24
    case -1: return baseY + (eventHour - 12)*hourHeight            // day N-1: last 12h → -12..0
                              // i.e. eventHour=12 → baseY, eventHour=24 → baseY+12h
    case +1: return baseY + (24 + eventHour)*hourHeight            // day N+1: first 12h → 24..36
    default: preconditionFailure("off-window occurrence reached render loop")
    }
}
```

Off-window occurrences (`|dayOffset| > 1`) are dropped in an explicit filter
BEFORE the render loop, inside the coordinator's `pushOccurrencesForDay`
(see §4a `setOccurrences`). Render-path Y math therefore never sees an
out-of-window occurrence. **Never use `.nan` as a sentinel** —
`CGRect` / `CGPath` APIs propagate NaN unpredictably, producing
`<Error>: invalid context` console spam and indeterminate `hitTest`
behavior (touch silently lands on a different sibling).

Substituting per the spec preamble:

- Day N event at `eventHour=H`: `absoluteY = headerHeight + allDayHeight + (12+H)*hourHeight`.
- Day N-1 event at `previousDayHour=P` (P ∈ [12,24]):
  `absoluteY = headerHeight + allDayHeight + (P-12+12)*hourHeight = headerHeight + allDayHeight + P*hourHeight`
  but offset by -12h from baseY; same algebra as the prompt.
- Day N+1 event at `nextDayHour=N` (N ∈ [0,12]):
  `absoluteY = headerHeight + allDayHeight + (12+24+N)*hourHeight = headerHeight + allDayHeight + (36+N)*hourHeight`.

`contentSize.height` is constant per `hourHeight`:

```
contentSize.height = headerHeight + allDayHeight + 48*hourHeight + bottomInset
```

It does NOT change when the band opens / closes. The pinch path still
re-derives it when `hourHeight` changes — that's expected and already
handled in S3.

Band visibility is implemented as `contentInset` mutations:

| Band-leading | Band-trailing | `contentInset.top` | `contentInset.bottom` |
|---|---|---|---|
| closed | closed | `-12*hourHeight` | `-12*hourHeight` |
| open | closed | `0` | `-12*hourHeight` |
| closed | open | `-12*hourHeight` | `0` |
| open | open | `0` | `0` |

Negative `contentInset` is well-defined for `UIScrollView` (it shifts the
scrollable range without changing `contentSize`). The user's scroll range
starts at `12*hourHeight` into the content when the leading band is closed;
scrolling up further is hard-stopped at that boundary, exactly as the SwiftUI
path's clamp does today.

Required at host construction (set explicitly in
`TimelineScrollHost.makeUIView` at S2):
`scrollView.contentInsetAdjustmentBehavior = .never` and
`scrollView.automaticallyAdjustsScrollIndicatorInsets = false`. Default
behaviors would compound `safeAreaInsets` into the negative inset and shift
the scrollable origin, producing an off-by-safe-area visual mismatch
between the band-closed mathematical 0:00 and the user-visible 0:00.

**Net:** the band collapse close path becomes one line:
`scrollView.contentInset.top = -12 * hourHeight`. No `contentSize` write,
no `contentOffset` compensation, no `coCommit`, no
`applyCloseBandStateAtomicCoCommit`, no leading-stale compensation
transform. The two-write-surface race class disappears because **there is
only one write surface**: a `contentInset` field on a `UIScrollView`.
Renderer math doesn't reference band state at all. The day-layer paints
the same `absoluteY` value before and after; only what the user can scroll
to has changed.

**Per-host fork (48h vs. 24h)**: `DayLayerHostView` is one class but
single-day uses the 48h model and multi-day still uses the existing 24h
model. The fork lives on a new `Model` field
`Model.useExtendedBandWindow: Bool` (default `false`). When `false`:
existing 24h math + 24h `contentSize` derivation + the old
`leadingExtendedHours` / `trailingExtendedHours`-conditional offset.
When `true`: the 48h-constant math above + boundary occurrence supply
expected from §S1. The flag is set per-host by the coordinator (`true` in
single-day mode, `false` in multi-day). All three render paths
(`render` / `repaintVertical` / `cullViewport`) gate Y math and slot-count
derivation on this single field. Per memory
`project_calayer_timeline_render_paths`: the gate must apply to all three
or one fast-path will revert geometry on the next scroll / pinch / live
adjust. `Model.useExtendedBandWindow` ships as part of S0 (see §5).

### 2B. Day-layer off the SwiftUI tree (Path B)

`CalendarDayLayerView` (the `UIViewRepresentable`) is **retired for
single-day mode** (initial scope). Multi-day mode keeps the SwiftUI wrapper
for now; multi-day's horizontal pager has its own propagation surface that
isn't part of this refactor.

A new MainActor-isolated class drives the host:

```swift
@MainActor
final class DayLayerCoordinator: NSObject {
    // Hosts keyed by dayOffset from the currently centered day (single-day
    // mode: typically just 0; week buffer: -3...3).
    private(set) var hosts: [Int: DayLayerHostView] = [:]
    private var freePool: [DayLayerHostView] = []                 // S6-style reuse

    weak var container: UIView?                                   // == scrollView.contentView host
    weak var scrollView: UIScrollView?                            // for contentInset writes

    // Snapshot of the global state the day-layer reads. Coordinator pushes
    // deltas on each setter; never observed by SwiftUI.
    private(set) var focusedEventID: UUID?
    private(set) var focusedOccurrenceID: String?
    private(set) var graceResize: GraceResize?
    private(set) var dragState: EventDragState?                  // shared @Observable (kept)
    private(set) var pinchHourHeight: CGFloat = 48
    // ... etc, one private(set) per channel in §3
}
```

The coordinator's surface is **imperative push methods**. Each is
synchronous and called from `CalendarPageView`'s existing event handlers /
`.onChange` observers / gesture callbacks. No SwiftUI Bindings cross the
boundary. The coordinator owns no `@Published` / `@Observable` of its own
either — there is no observer chain to await.

---

## 3. State channel inventory

Sourced from `CalendarDayLayerView(...)` (`TimelineView.swift:2538-2580`) plus
the `Model` struct (`CalendarDayLayerView.swift:196-249`) and the
`Callbacks` struct (`CalendarDayLayerView.swift:598`). Today every channel
is a struct field re-injected on each SwiftUI body eval; Path B routes
each to a coordinator setter. The inventory table below is the canonical
count (grepped against `TimelineView.swift:2538-2580`); see the section
summary for totals.

File-path note: on main today, `final class DayLayerHostView: UIView` lives
inline at `CalendarDayLayerView.swift:192`. Once PR \#86's
`refactor-split-calendar-day-layer-view` branch merges it will move to its
own `DayLayerHostView.swift` file (sibling location under
`Done/Views/Calendar/Components/Timeline/`). Citations in this doc are
written against main; re-grep after \#86 lands.

| # | Channel | Source (`CalendarPageView` state / setting) | Push shape | Scope | Today's path | Path B |
|---|---|---|---|---|---|---|
| 1 | `date` | `dayDate(forOffset:)` | one-shot per host | per-day | struct field, every body | `coordinator.addHost(dayOffset:date:)` |
| 2 | `occurrences` | `CalendarLayout.timelineVisibleOccurrences(forDayOffset:…, occurrencesForOffset:)` | per-day-cache-rebuild edge | per-day | struct field | `coordinator.setOccurrences(dayOffset:_:)` (S1: returns 48h window) |
| 3 | `contentWidth` | `dayWidth` from layout | per-layout | per-day | struct field | `coordinator.setContentWidth(dayOffset:_:)` (rare) |
| 4 | `headerHeight` | `calendarTimelineTopInset(hourHeight:)` | per-pinch | global | struct field | `coordinator.setHeaderHeight(_:)` |
| 5 | `hourHeight` | `calendarState.timelineHourHeight` | per-pinch frame (60–120 Hz) | global | `@Binding` + `liveHourHeight` ref-box | `coordinator.setHourHeight(_:)` (pinch coordinator calls direct) |
| 6 | `eventHorizontalInset` | `8` single-day / `4` multi-day | mode-flip | global | struct field | constructor / `setMode(_:)` |
| 7 | `leadingExtendedHours` | `boundaryExtensionHours.leading` | drag begin/end + auto-collapse | global | struct field, fires re-eval | **REMOVED in 48h model** (always notional 12) |
| 8 | `trailingExtendedHours` | `boundaryExtensionHours.trailing` | drag begin/end + auto-collapse | global | struct field | **REMOVED in 48h model** |
| 9 | `showEventText` | mode (`.preview` flag) | const-ish | global | struct field | constructor |
| 10 | `isWeekMode` | `rangeMode == .week` | mode-flip | global | struct field | `setMode(_:)` (single-day coordinator: const false) |
| 11 | `isThreeDayMode` | `rangeMode == .threeDay` | mode-flip | global | struct field | `setMode(_:)` |
| 12 | `titleFontSizeSetting` | `@AppStorage calayerTitleFontSize` | setting-flip | global | struct field | `coordinator.setTitleFontSize(_:)` |
| 13 | `showTimeBelowTitle` | `@AppStorage calayerShowTimeBelowTitle` | setting-flip | global | struct field | `coordinator.setShowTimeBelowTitle(_:)` |
| 14 | `multiTypeEnabled` | `@AppStorage calayerMultiTypeEnabled` | setting-flip | global | struct field | `coordinator.setMultiTypeEnabled(_:)` |
| 15 | `nearFutureHorizonDays` | `@AppStorage nearFutureHorizonDays` | setting-flip | global | struct field | `coordinator.setHorizonDays(_:)` |
| 16 | `isPinchActive` | `isRangePinchActive` (`@State`) | gesture begin/end | global | struct field | `coordinator.setPinchActive(_:)` |
| 17 | `frozenSlotMinutes` | `rangePinchFrozenSlotMinutes` (`@State`) | pinch begin/end | global | struct field | `coordinator.setFrozenSlotMinutes(_:)` |
| 18 | `dayColumnStep` | `isSingleDay ? 0 : width + daySpacing` | mode/layout flip | per-day | struct field | const in single-day (always 0) |
| 19 | `dragPreviewDayStep` | `width + daySpacing` | layout | per-day | struct field | `setDragPreviewDayStep(_:)` |
| 20 | `creationPreviewRange` | `creationPreviewByDay[offset]` or `previewCreation` | per-drag-frame (creation) | per-day | struct field | `coordinator.setCreationPreviewRange(dayOffset:_:)` |
| 21 | `focusedEventID` | `focusedEventID` (`@State`) | focus-enter / -exit | global | struct field, fires N day re-eval | `coordinator.setFocus(eventID:occurrenceID:)` |
| 22 | `focusedOccurrenceID` | `focusedOccurrenceID` (`@State`) | focus-enter / -exit | global | struct field | (combined with #21) |
| 23 | `graceResizeEventID` | `resizeGraceState.eventID` (`@State`) | resize-grace begin/expire | global | struct field | `coordinator.setGraceResize(eventID:occurrenceID:opacity:)` |
| 24 | `graceResizeOccurrenceID` | `resizeGraceState.occurrenceID` | grace begin/expire | global | struct field | (combined with #23) |
| 25 | `graceResizeHandleOpacity` | `resizeGraceFadeOpacity` (`@State`) | per-fade-tick (~10 Hz over 0.6 s) | global | struct field | (combined with #23 — fade ticker calls setter) |
| 26 | `isFocusContextActive` | derived `focusedEventID != nil` | mirror of #21 | global | struct field | derived inside coordinator |
| 27 | `recentlyAbsorbedEventIDs` | `calayerRecentlyAbsorbedParents` (`@State`) | absorb commit + 0.6 s expire | global | struct field | `coordinator.setRecentlyAbsorbedEventIDs(_:)` |
| 28 | `dragState` | `timelineDragState` (`EventDragState`, shared @Observable) | per-drag-frame for offset; coarse for identity | global | struct field (passed by reference) | **stays shared @Observable** — `coordinator.setDragState(_:)` once; gesture layer still writes per-frame, coordinator reads on push paths |
| C1 | `onEventTap` | `handleTimelineEventTap` | one-shot | n/a | closure field | `coordinator.delegate?.onEventTap(...)` |
| C2 | `onEventLongPressBegan` | `handleTimelineLongPressBegan` | one-shot | n/a | closure | delegate |
| C3 | `onEventManipulationPromotion` | `handleTimelineManipulationPromotion` | one-shot | n/a | closure | delegate |
| C4 | `onEventLongPressResolved` | `handleTimelineLongPressResolved` | one-shot | n/a | closure | delegate |
| C5 | `onEventDragEnded` | `handleTimelineEventDragEnded` | one-shot | n/a | closure | delegate |
| C6 | `onEventResizeEnded` | `handleTimelineEventResizeEnded` | one-shot | n/a | closure | delegate |
| C7 | `onCreateEvent` | `handleTimelineCreateEvent` (bound with `date`) | one-shot | n/a | closure | delegate |
| C8 | `onCreationPreviewChanged` | `updateCreationPreviewMapping` (host fan-out) | per-drag-frame (creation) | n/a | closure | delegate |
| C9 | `onNonEventTap` | `handleTimelineNonEventTap` | one-shot | n/a | closure | delegate |
| C10| `onHorizontalBoundaryPageRequest` | `requestHorizontalBoundaryPage` | per-edge-paging | n/a | closure | delegate |
| C11| `onVisibleTimelineFrameChange` | `handleVisibleTimelineFrameChange` | per-layout / scroll | n/a | closure | delegate (but see §7: derived from CALayer geometry now, not SwiftUI `GeometryReader`) |

Total: 28 input channels + 11 callbacks = **39 distinct channels** mapped.
(Channels #7 + #8 fold away under the 48h model — the coordinator API for
single-day mode does not expose them at all. Channels #21+#22+#26,
#23+#24+#25, and others are grouped into single setter methods.)

After grouping and the 48h collapse, the coordinator's actual setter
surface is approximately **15 methods** (§4).

---

## 4. Concrete API sketches

### 4a. `DayLayerCoordinator`

```swift
@MainActor
final class DayLayerCoordinator: NSObject {

    // -- lifecycle / topology ---------------------------------------------
    init(container: UIView, scrollView: UIScrollView, dragState: EventDragState)
    func addHost(dayOffset: Int, date: Date, frame: CGRect)
    func removeHost(dayOffset: Int)
    func setMode(_ mode: RangeMode)                          // .day / .threeDay / .week
    func setContentWidth(_ width: CGFloat, for dayOffset: Int)
    func setDragPreviewDayStep(_ step: CGFloat)

    // -- per-scroll-frame inset writes (the 48h model's only band channel)-
    func setBandLeadingOpen(_ open: Bool)                    // toggles contentInset.top
    func setBandTrailingOpen(_ open: Bool)                   // toggles contentInset.bottom

    // -- per-pinch sync push (hot path — 60..120 Hz) ----------------------
    func setHourHeight(_ height: CGFloat)                    // also rederives contentSize.height
    func setPinchActive(_ active: Bool)
    func setFrozenSlotMinutes(_ minutes: Int?)

    // -- focus / grace / drag / absorb broadcasts -------------------------
    func setFocus(eventID: UUID?, occurrenceID: String?)
    func setGraceResize(eventID: UUID?, occurrenceID: String?, opacity: Double)
    func setRecentlyAbsorbedEventIDs(_ ids: Set<UUID>)
    func setCreationPreviewRange(_ range: Event.TimeRange?, for dayOffset: Int)
    func setOccurrences(_ occs: [CalendarLayout.EventOccurrence], for dayOffset: Int)

    // -- one-time chrome / setting writes ---------------------------------
    func setHeaderHeight(_ h: CGFloat)
    func setEventHorizontalInset(_ inset: CGFloat)
    func setTitleFontSize(_ size: Double)
    func setShowTimeBelowTitle(_ on: Bool)
    func setMultiTypeEnabled(_ on: Bool)
    func setHorizonDays(_ days: Int)
    func setShowEventText(_ on: Bool)

    // -- output delegate ---------------------------------------------------
    weak var delegate: DayLayerCoordinatorDelegate?
}

protocol DayLayerCoordinatorDelegate: AnyObject {
    func dayLayer_onEventTap(_ event: Event, on date: Date)
    func dayLayer_onLongPressBegan(_ began: CalendarEventLongPressBegan)
    func dayLayer_onManipulationPromotion(_ event: Event, occurrenceID: String?,
                                          date: Date, mode: EventDragMode,
                                          point: CGPoint, frame: CGRect)
    func dayLayer_onLongPressResolved(_ res: CalendarEventLongPressResolution)
    func dayLayer_onDragEnded(_ event: Event, occurrenceID: String?,
                              range: Event.TimeRange, offset: DragOffset, hourHeight: CGFloat)
    func dayLayer_onResizeEnded(_ event: Event, occurrenceID: String?,
                                range: Event.TimeRange, anchor: Date,
                                mode: EventDragMode, hourHeight: CGFloat)
    func dayLayer_onCreateEvent(_ range: Event.TimeRange, on date: Date)
    func dayLayer_onCreationPreviewChanged(_ day: Date, range: Event.TimeRange?)
    func dayLayer_onNonEventTap()
    func dayLayer_onHorizontalBoundaryPageRequest(direction: Int) -> Bool
    func dayLayer_onVisibleTimelineFrameChange(_ rect: CGRect)
}
```

### 4b. `DayLayerHostView` changes

`DayLayerHostView` keeps its existing `apply(model:callbacks:)` signature
internally — the coordinator constructs a `Model` snapshot from its own
state and pushes it. The persistent layer tree (`gridLayer`, `nowLineLayer`,
event subtree pool) is unchanged.

Concretely, the coordinator's setters do one of two things:

1. Mutate a single field on a cached `Model`, then call
   `host.apply(model:callbacks:)`. The host's existing structural-key vs
   visual-state diff (`Model.visualStateEqual(_:_:)`,
   `CalendarDayLayerView.swift:238-249`) already short-circuits when only
   visual fields changed — that diff is what makes per-frame pinch cheap
   today and stays valid.
2. For the hot per-frame paths (`setHourHeight`, `setDragState` mirror),
   **every coordinator push MUST update the cached `Model` field first**;
   fast-path callbacks may THEN bypass `apply(model:)` and call
   `host.repaintVertical(_:)` / `host.liveAdjustOccurrence(...)` directly.
   The cached `Model` is always the source of truth — a subsequent
   `apply(model:callbacks:)` (e.g., on the next non-hot-path change) reads
   from the updated `Model`. This rules out drift between the hot-path
   writer and the slow-path writer (the exact dual-path pattern called out
   in memory `feedback_calayer_parity_multi_state_gates` — the resize-extend
   bug was a fast-path that revert-wrote the block back to the static Model
   on the next render). The three render paths
   (`render` / `repaintVertical` / `cullViewport`) already gate on
   `liveAdjustedOccurrence` for drag (per memory
   `project_calayer_timeline_render_paths`), so the coordinator's drag-frame
   sequence is: write to cached `Model.dragState`, then call
   `liveAdjustOccurrence(...)` for the visible frame.

### 4c. `CalendarPageView` changes

What disappears in single-day mode (when
`calendarUseImperativeDayLayer == true`):

- `applyCloseBandStateAtomicCoCommit` (CalendarPageView:1150-1257) — dead.
- The three close-path forks at CalendarPageView:3051-3055, 3098-3107,
  3242-3252 collapse to a single non-forked path: `coordinator.setBandLeadingOpen(false)` /
  `setBandTrailingOpen(false)`. No `coCommit`, no `dim`, no
  `transientHostYCompensation`, no `applyCloseLeadingTransientCompensation`,
  no `compensationClearDisplayLink`.
- `TimelineScrollProxy.coCommit` becomes effectively unused for single-day.
  It can stay (multi-day still wires it) as a no-op caller or, cleaner,
  guard at the call site.
- The `extensionFadeMask` (TimelineView:2592-2623) is no longer required to
  paper over a stale-band frame. (Whether to keep it cosmetically is a
  separate question — see open questions.)
- The `boundaryExtensionScrollAnimator` + `pendingBoundaryExtensionScrollTask`
  reentry machinery for the close path becomes irrelevant. The open path
  (band extend during cross-midnight drag) still needs the same animator,
  because the user expects a smooth scroll when the band auto-extends.

What gets added in `CalendarPageView`:

- A `@StateObject private var dayLayerCoordinator = DayLayerCoordinator(...)`
  on `CalendarPageView` directly (struct declaration at CPV:1026). This is
  ABOVE the `.id(rebuildKey)` boundary — the modifier is INSIDE on the
  pager subview (CPV:3672, attached to `timelineLayer`), not on
  `CalendarPageView` itself — so the coordinator survives rangeMode
  `.day` ↔ `.week` / `.threeDay` flips. See §10 Q1 for the
  decision-with-mitigation framing.
- Replace the `buildDayLayerView(for:date:dayWidth:…)` call site with a
  no-op SwiftUI view, plus a one-shot effect that
  `coordinator.addHost(dayOffset: 0, date: today, frame: hostFrame)` when
  the page first appears.
- For every state channel currently fed via the `CalendarDayLayerView(...)`
  struct field, add an `.onChange(of: X) { newValue in coordinator.setX(newValue) }`
  observer. Each is a single synchronous setter call. The Bindings (#5, #18)
  become callbacks → coordinator-issued mutations + writeback.

### 4d. `TimelineScrollHost` integration

`TimelineScrollProxy` exposes a new `setContentInsetTop(_:)` /
`setContentInsetBottom(_:)` pair. The coordinator owns these calls (or holds
the proxy directly). `coCommit` stays — multi-day still uses it until S6 —
but is no longer wired by the close paths.

The host content view (`UIHostingController`'s view) becomes a UIKit
container view in single-day mode: the day-layer is added as a subview of
the scroll view's contentView directly, NOT through `UIHostingController`.
The all-day section, axis, and chrome that remain SwiftUI sit beside it as a
sibling `UIHostingController` (height computed from `allDayHeight` +
`headerHeight`, pinned to top of contentView).

---

## 5. Slice sequence (S0–S7)

Each slice is independently mergeable. Each builds green. At slice
boundaries with the flag OFF, behavior is unchanged. The flag is
`calendarUseImperativeDayLayer` (new), default OFF until S7.

Relationship to PR \#89's `calendarUseUIScrollViewTimeline`: **stacking
prerequisite**. The imperative day-layer pushes its content view as a
direct subview of `UIScrollView.contentView`, so the UIScrollView path
must already be live. Until UIScrollView is the default vertical surface,
this slice arc cannot ship. The two flags can both be ON during
development; if `calendarUseUIScrollViewTimeline` is OFF, the imperative
day-layer simply does not engage (`CalendarPageView` falls back to the
`CalendarDayLayerView` SwiftUI representable).

| Slice | Scope | Verifies against | Notes |
|---|---|---|---|
| **S0** | Ship three atomic deliverables together under flag `calendarUseImperativeDayLayer` in single-day mode: (i) 48h-constant Y math in `DayLayerHostView.render()` / `repaintVertical(_:)` / `cullViewport(visibleRect:)`, gated on the new `Model.useExtendedBandWindow` field (§2A); (ii) `contentSize.height` formula switches to `headerHeight + allDayHeight + 48*hourHeight + bottomInset` when the field is true (current `repaintVertical` already re-derives contentSize on `hourHeight` change — the formula constant is the change); (iii) initial `scrollView.contentInset.top = -12*hourHeight` and `.bottom = -12*hourHeight` when the band is closed (i.e., on first install / flag-ON cold-start). Without all three landing in the same commit, day-N's 14:00 event renders OFF the scrollable area when the band is closed — S0 is not behavior-neutral piecewise. Flag-gated default OFF; multi-day unchanged. Acceptance: toggle flag ON in single-day mode → events render at the correct visual position, band hidden, no events off-screen, all-day pill row still sits flush with the top of the visible scroll range. | spec 03 §vertical mapping; visual A/B on flag toggle; the single acceptance test above is the hard gate | Per memory `project_calayer_timeline_render_paths`: the Y-math + contentSize derivation must touch all three render paths or one fast-path will revert geometry on the next scroll/pinch. |
| **S1** | Extend the host's occurrence supply. Add a `coordinator.setOccurrences(_:for:)` (initially still routed through the SwiftUI `CalendarDayLayerView`) that returns boundary day occurrences too in single-day mode: dayOffset 0 supplies its own + last 12 h of dayOffset -1 + first 12 h of dayOffset +1, all with `dayOffset` tagged so the host's Y math (S0) picks the right branch. `CalendarLayout.timelineVisibleOccurrences` already supports this via `leadingExtendedHours` / `trailingExtendedHours` — single-day passes those as constant 12, 12 always. | spec 03 occurrence injection; spec 05 §6 | The host already paints cross-midnight events; the only change is keeping the band hours constant. |
| **S2** | `contentInset`-based band visibility on `TimelineScrollHost`. Add `setContentInsetTop(_:)` / `setContentInsetBottom(_:)` to the proxy. On flag ON: every band-open/close goes through inset writes — delete `applyCloseBandStateAtomicCoCommit` invocations at CPV:3051, 3105, 3245 (replace with inset writes). `coCommit` body becomes no-op when called on the single-day flag-ON path (we can keep the call site for now and short-circuit inside, then delete the call sites in S7). Open-band path: cross-midnight drag still requests an extension; in the 48h model this becomes `setBandLeadingOpen(true)` + an animated `setContentOffset` to scroll into the now-exposed band, replacing the SwiftUI fade + scroll animator pair. | spec 04 §boundary extension; \#57 / \#82 / \#80 regression-fixed | This is the milestone slice: PR \#89's race class is gone after S2 ships, even before the imperative coordinator. The remaining slices migrate the host off SwiftUI for the perf / lifecycle wins. |
| **S3** | Introduce `DayLayerCoordinator` scaffolding (alongside the existing SwiftUI path; not yet wired into the view tree). The coordinator can be constructed and stepped through unit tests; `CalendarPageView` does NOT yet construct one. | code scaffolding only | Allows S4 PRs to migrate channels one at a time without touching state-injection wiring. |
| **S4** | Migrate one state channel at a time from SwiftUI struct field to coordinator setter. Recommended order: focus → grace → recentlyAbsorbed → creationPreviewRange → pinchHourHeight → dragState mirror → settings (font, time-below, multi-type) → mode / horizon. Each channel is its own commit (~11 commits inside S4). Each migration disables the corresponding struct field on the flag-ON path and routes the value through `coordinator.setX(_:)` instead. | spec 05 §3 channel-by-channel | After this slice every channel has BOTH paths wired; flag-OFF still uses SwiftUI, flag-ON uses coordinator. |
| **S5** | Cut the `CalendarDayLayerView` `UIViewRepresentable` cord in single-day mode. SwiftUI tree's `buildDayLayerView` returns `Color.clear` when flag ON + `rangeMode == .day`; the coordinator's host is added as a sibling subview of the scroll content. Multi-day still constructs `CalendarDayLayerView` via the representable. **Hard gate**: all 11 S4 channel-migration sub-commits must be merged before S5 can land. Verify by `grep` over `CalendarPageView.swift` that no channel is still only on the SwiftUI representable path (every channel either reads from `coordinator.<setter>` or has both paths wired). Also: delete `extensionFadeMask` in this slice per §10 Q3. | structural — the day-layer host is no longer in the SwiftUI tree | Solves the propagation race at the framework level; no SwiftUI body eval gates a day-layer Model update. |
| **S6** | Retire or thin `TimelinePagerView` for single-day mode (the SwiftUI horizontal pager). Open question — see §10 — whether to keep it for multi-day and just bypass it for `.day`. The decision affects whether S5's "sibling subview" placement is final or transitional. | spec 06 §boundary placement | May be deferred to a follow-up if §10's open question pushes back. |
| **S7** | Parity sign-off pass (all of specs 01 / 02 / 03 / 04 against the flag-ON single-day path), flip `calendarUseImperativeDayLayer` default to ON, delete the SwiftUI fallback for `.day`. Multi-day continues with the SwiftUI representable until a separate follow-up addresses it. | full parity checklist | Mirror of spec 06 S7. |

Slice count: **8** (S0…S7).

---

## 6. Parity checklist (riskiest items)

Pulled from specs 01 / 02 / 04. Don't repeat the full lists — name what this
refactor risks regressing.

From **02 §1.1–1.2 (recognizer + hit area, G-1…G-10)**: any change to how the
event hit area receives touches risks regressing the fall-through inset
(G-4 / G-5). The imperative host is the same UIView, but it's no longer
inside a SwiftUI view that mirrors `.contentShape` — the SwiftUI shape stays
attached to the (now removed) representable wrapper. We must move the
matching `.contentShape` to the all-day section's parent, or rebuild the
fall-through region into the layer's `hitTest(_:with:)` directly.

From **02 §1.8 (scroll suppression, G-33–G-34)**: `disableScrollPanGesturesForDrag`
walks the ancestor chain. With the day-layer hosted directly in
`UIScrollView.contentView`, the ancestor walk picks up the same scroll view
as before; this should not regress. Re-verify after S5.

From **02 §3 (single-day boundary paging, G-42–G-45)**: paging continues to
fire `onHorizontalBoundaryPageRequest`. The 48h model does NOT change the
horizontal page surface (we are operating inside a single vertical column).
But note that the coordinator's per-host `dayOffset` keying becomes
authoritative; paging must update the coordinator's centered offset
synchronously with the SwiftUI page change. **G-44** is the parity gate.

From **02 §7.1 (PinchScrollCoordinator, G-68–G-72)**: pinch attaches a
`UIPinchGestureRecognizer` to the nearest ancestor `UIScrollView`. The
imperative host still lives inside one (UIScrollView path is a prereq), so
attachment is preserved. G-71's `isInteractionBlocked` gate continues to
read the shared `EventDragState`.

From **01 §13 (focus opacity)**: focused sibling dimming (0.28 opacity) is
driven by `focusedEventID`. Channel #21 migration must produce the dim
edge synchronously with the SwiftUI host's existing focus animation
(spec 04 §focus enter, 0.18 s ease-out scale). If `coordinator.setFocus`
fires later than the SwiftUI animation tick, the dim and the scale will
desync — keep them on the same caller frame.

From **01 §16 (compound interrupt cutout)**: silhouette path math is per
host, unchanged. Re-verify after S0 / S1 because Y-math change is upstream.

From **04 §4 (absorption pulse) & §5 (drop-target scale)**: pulse triggered
by `recentlyAbsorbedEventIDs` insert. Channel #27 setter must fire on the
same call frame as the absorption commit, mirroring today's edge-driven
animation.

---

## 7. Risks (explicit)

### 7a. Cross-column drag (3-day, week)

The initial slice is single-day. Multi-day cross-column drag (move a block
from Tuesday into Thursday) crosses multiple `DayLayerHostView` instances.
With multiple hosts, the gesture coordinator (currently per-host) must hand
off drag state across hosts. Today this is "free" because the
`EventDragState` is shared and every host SwiftUI-observes the same fields.
In Path B, the coordinator broadcasts to all hosts on `setDragState` mirror
pushes. The hot path (`dragOffset` per frame) STAYS in `EventDragState`
field-tracking — per spec 05 §7 the rewrite mustn't push that through
coarse publishing. The coordinator's per-host fan-out only handles
identity edges (`draggingEventID`, `currentDropTargetEventID`, `dragMode`).

### 7b. Pinch hourHeight at 60–120 Hz

`setHourHeight` is the hottest channel. Today the `liveHourHeight`
ref-box (spec 05 §1b) lets `EventBlock` read the live value without
struct-field invalidation. In Path B, `coordinator.setHourHeight` calls
into `host.repaintVertical(_:)` synchronously — same render path the
SwiftUI pinch uses. The performance question is whether calling
through `apply(model:)` is fast enough at 120 Hz with a 48h model.
`repaintVertical` already iterates only visible occurrences; the 48h
window adds at most 2× the events (24h day + 24h of neighbor days). Spec
03's pinch benchmark (S3 baseline) must be re-run after S4 to confirm.

### 7c. `rangeMode` `.day` → `.week` → `.day` lifecycle

A user switching to week and back must not leak host instances or fail to
rewire the coordinator. The coordinator owns the host pool (`freePool`)
and the active host map; `setMode(.week)` adds 6 more hosts (week buffer
−3…+3), `setMode(.day)` returns 6 hosts to the pool. The lifecycle is
explicit and inspectable. The SwiftUI side's `rebuildKey` `.id(...)`
attaches to `timelineLayer` (CPV:3672), INSIDE `CalendarPageView`'s body —
the coordinator is `@StateObject` on `CalendarPageView` itself
(CPV:1026), one level outside that boundary, so the coordinator is NOT
rebuilt on range change.

Tab-switch / app-backgrounding addendum: on `CalendarPageView` disappear
(Calendar tab → Wanna tab, or app → background), the SwiftUI view tree
may tear down the pager's subview tree, dropping the host `UIView`
instances even while the coordinator's `@StateObject` survives. The
coordinator's `hosts` dict and `freePool` must therefore be reconstructible
from `@State` alone: setters are idempotent, tolerate empty pools, and a
post-reappearance call to `coordinator.addHost(dayOffset: 0, date: today,
frame: hostFrame)` re-installs the host with the current cached `Model`.
Verify in §S7 parity test (Calendar tab → Wanna tab → Calendar tab →
cross-midnight drag should still work without re-launch).

### 7d. Focus mode entry/exit

Focus enter mutates `focusedEventID` once; with N hosts, the SwiftUI path
re-evaluates N day bodies. The coordinator path calls `setFocus` once and
broadcasts to N hosts in a single MainActor frame. The broadcast must be
synchronous; if any host's repaint is async-deferred, we get the same race
class we're trying to kill. All host repaints in this path run on the
calling stack.

### 7e. 48h model + now-line

The now-line layer paints only in "today" (`dayOffset == 0`). Its absoluteY
must respect the 48h-constant offset, exactly like event absoluteY does.
This is one constant addition (`baseY + nowHourFraction*hourHeight`) and
already covered by the S0 change. The mask geometry (#80) is computed
from the same constant.

### 7f. Hit-test in the band-hidden region

When `contentInset.top = -12*hourHeight`, the top 12 h of content is
unscrollable but still rendered. Events painted in the band region must
NOT be tappable when the band is closed — otherwise a tap in the top 12 h
(reached by scrolling above the apparent 0) hits an event the user can't
see. The host's `hitTest(_:with:)` must reject points where
`y < baseY` (band-leading-closed) and `y > baseY + 24*hourHeight`
(band-trailing-closed). This is one bounds check at the host level.

### 7g. Boundary day hints (\#88, just landed)

\#88 paints "hints" of yesterday's late events and tomorrow's early events
during the closed-band state, in the day-N's column at the top/bottom edges.
Implementation reads `leadingExtendedHours` / `trailingExtendedHours` to
decide hint placement. In the 48h model those Model fields go away in
single-day mode. The hint placement code must derive from the
coordinator's `bandLeadingOpen` / `bandTrailingOpen` booleans instead — a
direct one-line conversion, but it's a required change to land alongside
S2.

---

## 8. Out of scope

- Multi-day horizontal pager (`TimelinePagerView` SwiftUI `ScrollView` +
  `LazyHStack` for 3-day / week). Stays SwiftUI; multi-day day-layer hosts
  still go through `CalendarDayLayerView` `UIViewRepresentable`.
- `allDaySection` (all-day pill row, TimelineView:2417–2451). Stays
  SwiftUI; sits above the imperative day-layer in the column.
- `extensionFadeMask` (\#62 — separately tracked). With the 48h model the
  fade no longer hides a stale frame; per §10 Q3, decided to delete at S5
  when the SwiftUI `.mask { extensionFadeMask() }` modifier goes away with
  the representable cord. Cosmetic-only follow-up if dogfood demands it.
- Surface ports already shipped: \#74 axis markers, \#85 focus event flow,
  \#83 mini-day, \#88 boundary day hints, \#87 cleanup, \#86 split. \#88
  needs the §7g touch-up alongside S2 but no rework.

---

## 9. Verification harness

- **`TimelineRenderBenchmarkTests`** (spec 06 §verification): re-run at S0
  (Y-math change), S4 (per-channel pinch push), and S5 (host out of SwiftUI
  tree). Spec 03's pinch benchmark is the hard gate at S4.
- **Spec parity checklists as pass/fail**: every G-n in spec 02 (85 items),
  every numbered item in spec 01 (16 items), every spec 04 animation (20
  items). Run as a literal A/B per slice boundary.
- **Manual A/B via the flag**: with `calendarUseImperativeDayLayer` toggled
  in the settings A/B panel (mirror of `calendarUseUIScrollViewTimeline`),
  same fixture data, screen-record both, frame-diff.
- **Race-fixture tests**: scripted boundary-extension open / close /
  multi-side close that today reproduces the \#57 / \#82 / \#80 flashes.
  These should go from intermittent-flash to clean across S0 + S2.
- **Pinch + drag combo (single-source invariant)**: drag an event while a
  pinch is in flight. Verifies the cached `Model` stays consistent with
  hot-path `repaintVertical` / `liveAdjustOccurrence` writes (§4b point 2)
  — the next non-hot-path `apply(model:callbacks:)` after the combo ends
  must observe both writes; the block must not snap back to a pre-pinch or
  pre-drag position on the next render.
- **Coordinator state dump**: add a `coordinator.debugDumpState()` returning
  every push channel's last-observed value and the most recent push
  caller's symbol (captured via `#function`). Trace by hand on bug reports.
  Cheap to add, high value for debugging propagation order.

---

## 10. Open questions

1. **Where does the coordinator live? — Decided.** (a) `@StateObject` on
   `CalendarPageView` directly. Verified by inspection that
   `CalendarPageView` (struct at CPV:1026) does not have `.id(rebuildKey)`
   at its own boundary — the modifier is INSIDE on the pager subview
   (`timelineLayer`, CPV:3672), so the `@StateObject` survives rangeMode
   flips. Options not taken: (b) singleton on the app's calendar coordinator
   (needs explicit navigate-away teardown); (c) `UIViewControllerRepresentable`
   wrapping a controller that holds it (UIKit-owned lifecycle, redundant
   given (a) is safe). Residual risk: SwiftUI may reissue the `@StateObject`
   during navigation tear-down (Calendar tab → Wanna tab → Calendar tab) if
   `CalendarPageView` itself goes away. Mitigation: coordinator's `hosts`
   dict + `freePool` must be reconstructible from current
   `CalendarPageView` `@State` alone (idempotent setters; tolerate empty
   pool). Treat as "decided but verify in §S7 parity test" — kept in this
   list as a callout, not a true open question.

2. **Does multi-day stay on the SwiftUI representable indefinitely?** The
   propagation race in multi-day is rarer (no leading/trailing band on
   3-day / week today), so the urgency is lower. But the long-term answer
   shapes whether `CalendarDayLayerView` (the representable) becomes
   dead code (S5 only single-day) vs. a continued multi-day API.

3. **`extensionFadeMask` — Decided: delete in S5.** The mask's original
   purpose was to hide the 1-frame stale-Model mismatch during band close;
   the 48h model removes that mismatch at the math level. Without the cord
   to a `.mask { extensionFadeMask() }` SwiftUI modifier, the cosmetic fade
   disappears at S5. If post-merge dogfood reveals a cosmetic gap during
   auto-collapse, port the fade to a `CALayer` mask on the coordinator's
   UIView container as a follow-up — not load-bearing for the slice.

4. **`coCommit` retirement**: with single-day off it, multi-day may also
   not need it (multi-day doesn't have a leading/trailing band the same
   way). If multi-day's all paths become inset-only too,
   `TimelineScrollProxy.coCommit` plus all of PR \#89's compensation
   transform machinery is dead code. Should we plan a separate cleanup
   slice (S6.5?) to retire it?

5. **Drag mirror on multiple hosts**: in 3-day / week the coordinator
   broadcasts `dragState` identity-edge writes to all hosts. Today the
   shared `EventDragState` is field-tracked by SwiftUI per-host. If we
   keep the SwiftUI hosts for multi-day, the coordinator and the shared
   `EventDragState` BOTH push to those hosts. Confirm the two paths
   don't double-fire any handler.

6. **`onVisibleTimelineFrameChange` (#65, channel C11)**: today the frame
   comes from a SwiftUI `GeometryReader`. In Path B, the host computes
   the frame from CALayer bounds + scroll offset directly. Confirm the
   absorption hit-test (spec 05 §6, channel reader at CPV:2783) still
   receives the rect on the same frame the user sees the layer at.

7. **Coordinator interactions with the all-day section's tap handlers**:
   the SwiftUI all-day section above the imperative host fires
   `onEventTap` directly. If the user taps an all-day pill while the
   coordinator has a focus state set, the handler order must match
   today's (`handleTimelineEventTap` → `clearFocus`). Verify the routing
   when the all-day path is the SwiftUI sibling of the imperative host.
