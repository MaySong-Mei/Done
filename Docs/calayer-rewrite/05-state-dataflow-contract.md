# 05 — State Model & Data-Flow Contract

Scope: the EXACT INPUT (observed dependencies) / OUTPUT (callbacks) contract at the
`TimelinePagerView` boundary, plus the shared `EventDragState` and the
`CalendarPageView` host state. This is the contract a UIKit+CALayer
`UIViewRepresentable` must honor: **SwiftUI owns the data model (`EventStore` +
`CalendarPageView` @State); the UIKit calendar reads via injected dependencies and
writes back via callbacks.** Zero behavior change.

File anchors:
- `Done/Models/EventStore.swift` — the data model (ObservableObject)
- `Done/Views/Calendar/Components/Timeline/TimelineView.swift` — `EventDragState`,
  `TimelinePagerView`, `TimelineDayView`
- `Done/Views/Calendar/Components/Timeline/Event/EventBlock.swift` — the gesture
  layer that WRITES `EventDragState`
- `Done/Views/Calendar/CalendarPageView.swift` — the host (state + callback handlers)

---

## 0. Topology (who owns what)

```
EventStore (ObservableObject, @MainActor)          <- single source of truth, persisted
  @Published rawCalendarEvents: [Event]
  var canvasRenderableCalendarEvents (filtered)
        │  (read on every mutation via .onChange)
        ▼
CalendarPageView (@State host)                      <- owns derived caches + UI flags
  occurrencesCache: [Int:[EventOccurrence]]         (rebuilt from store)
  focusedEventID / focusedOccurrenceID, routes, menus, interrupt session…
  timelineDragState = EventDragState()              <- @Observable shared scratchpad
        │  (props in)            ▲ (callbacks out)
        ▼                        │
TimelinePagerView (UIViewRepresentable boundary)    <- READS props, CALLS callbacks
        │
        ▼
TimelineDayView ──► EventBlock + gesture coordinators  <- WRITE EventDragState live
```

The CALayer rewrite replaces `TimelinePagerView` + `TimelineDayView` + `EventBlock`.
The boundary props below are the **inputs**; the closures are the **outputs**; the
`EventDragState` object is **shared mutable scratch state** that crosses the boundary
in BOTH directions every drag frame.

---

## 1. INPUTS — properties the timeline READS

These are the deps the UIKit view must observe (or be injected with + re-injected on
change). Source = where the value originates. "Freq" = update frequency.
All line refs are `TimelinePagerView` declarations unless noted.

### 1a. Data model inputs (the event data)

| Prop | Type | Source | Drives | Freq | Ref |
|---|---|---|---|---|---|
| `occurrencesForOffset` | `(Int) -> [CalendarLayout.EventOccurrence]` | `occurrencesCache[$0] ?? []` (host) | The blocks rendered per day column. Closure injection — NOT a @Published array. | On store mutation / day-change / range expand | TimelineView 1149; host 2688 |
| `allDayOccurrencesForOffset` | `((Int) -> [EventOccurrence])?` | `allDayOccurrencesCache[$0]` | All-day pill row per day | same as above | 1150; 2689 |
| `maxAllDayCountOverride` | `Int?` | `maxAllDayCountCache` | All-day section height (avoids per-body dayRange scan) | on all-day cache change | 1153; 2690 |
| `dayRange` | `ClosedRange<Int>` | host `dayRange` (monotonically EXPANDS) | Which day offsets exist | rarely (expansion only) | 1165; 2699 |
| `daysCount` | `Int` | `timelineDaysCount(rangeMode)` | columns per page (1 / 3 / 7) | on rangeMode change | 1162; 2696 |
| `liveInterruptSession` | `CalendarInterruptLiveSession?` | host `@State` | live red interrupt bar / parent geometry | start/stop of a live interrupt | 1200; 2732 |

The occurrence data is **pull-based via a closure keyed by day offset**, NOT a
published array the view subscribes to. The host rebuilds `occurrencesCache` whenever
`store.rawCalendarEvents` changes (`CalendarPageView` 1260) or on day-change /
becomeActive / dayRange expand (1252–1361), then SwiftUI re-evaluates the body and the
closure returns fresh data. **The UIKit port must take the same closure (or an
equivalent "give me occurrences for offset N" callback) and be told when to re-pull**
— there is no KVO on the array. A `reloadData()`-style signal driven off the host's
existing `.onChange(of: store.rawCalendarEvents)` is the natural bridge.

`EventOccurrence` is already a flattened, layout-ready value (recurring series expanded
to a concrete day, absorbed todos filtered out upstream — see §6 filtering).

### 1b. Layout / zoom inputs

| Prop | Type | Binding? | Drives | Freq | Ref |
|---|---|---|---|---|---|
| `hourHeight` | `@Binding CGFloat` | **two-way** | vertical scale (pt per hour) | every pinch frame | 1156; 2693 |
| `liveHourHeight` | `CalendarHourHeightBox` (ref class) | injected ref | EventBlock reads live value WITHOUT body invalidation | every pinch frame (via ref, no rebuild) | 1160; 2694 |
| `selectedDayOffset` | `@Binding Int` | **two-way** | which day is centered / current page | on horizontal page | 1154; 2691 |
| `rangeMode` | `@Binding RangeMode` | **two-way** | day/3-day/week/month layout | on mode switch | 1155; 2692 |
| `isDayOffsetFrozen` | `Bool` | one-way | suppress offset updates during transitions | transient | 1161; 2695 |
| `mode` | `PageMode` (`.preview`) | const | preview vs other | const | 1163; 2697 |
| `showEventText` | `Bool` | one-way | render titles or bars only | on mode change | 1164; 2698 |
| `verticalScrollY` | `CGFloat` | one-way | pinch focal-point anchor math | every scroll frame | 1191; 2721 |
| `verticalViewportHeight` | `CGFloat` | one-way | pinch min-height calc | on layout | 1192; 2722 |
| `verticalContentTopInset` | `CGFloat` | one-way | pinch focal + top overlay | on layout | 1193; 2723 |
| `verticalContentBottomInset` | `CGFloat` | one-way | pinch min so 24:00 clears tab bar | on layout | 1197; 2724 |
| `boundaryExtensionStateOverride` | `TimelineBoundaryExtensionState?` | one-way | host-driven leading/trailing hour extension | during cross-midnight drag | 1199; 2731 |

Note `hourHeight` is a `@Binding` BUT the host wraps it in a custom getter/setter
(`timelineHourHeightBinding`, host 2680) that reads/writes `calendarState.timelineHourHeight`.
`liveHourHeight` is a **redundant reference-type mirror** of the same value — passed so
the deep `EventBlock` callee can read the live pinch value without its struct identity
changing each frame (perf hack). The CALayer port collapses these: one observed
`CGFloat` plus the live value held in the UIView; no `Box` indirection needed.

### 1c. Focus / selection / preview inputs (highlight state)

| Prop | Type | Drives | Ref |
|---|---|---|---|
| `focusedEventID` | `UUID?` | focused block scale-up; siblings dim to 0.28 opacity | 1167; 2701 |
| `focusedOccurrenceID` | `String?` | disambiguates which occurrence of a multi-range/recurring event is focused | 1168; 2702 |
| `previewCreation` | `PendingEventCreation?` | the ghost block during drag-create / pending sheet | 1166; 2700 |
| `previewHandleEventID` / `previewHandleOccurrenceID` / `previewHandleOpacity` | `UUID?` / `String?` / `Double` | resize handles on a non-grace preview (currently passed `nil`/`1`) | 1169–1171; 2703–2705 |
| `graceResizeEventID` / `graceResizeOccurrenceID` / `graceResizeHandleOpacity` | `UUID?` / `String?` / `Double` | post-commit "resize grace" handles that fade out | 1172–1174; 2706–2708 |

Focus + preview + grace are all **pure visual highlight inputs** sourced from host
`@State` — they do not feed back into the timeline's own state, only into rendering.

### 1d. Shared mutable input — `EventDragState`

| `dragState` | `EventDragState` (`@Observable` class) | TimelineView 1148; host 2687 |

This is BOTH an input and an output (see §3). Passed by reference. The timeline reads it
to render the live drag preview; `EventBlock`'s gesture coordinators write it every
frame. It is the one piece of fine-grained mutable state crossing the boundary.

---

## 2. OUTPUTS — callbacks the timeline CALLS

Every write-back path. "Fires when" + "mutates" describe the host handler behavior.
Signatures are the `TimelinePagerView` closure types; handlers are in `CalendarPageView`.

| Callback | Signature | Fires when | Host handler / state mutated | Ref |
|---|---|---|---|---|
| `onEventTap` | `(Event, Date) -> Void` | tap a block | `handleTimelineEventTap` → clears focus/menu/grace, sets `selectedEventDetailRoute` (opens detail) | TLV 1175; host 2752 |
| `onEventLongPressBegan` | `(CalendarEventLongPressBegan) -> Void` | long-press threshold reached | `handleTimelineLongPressBegan` → `scheduleFloatingMenuActivation` (sets `floatingMenuOccurrence`, arms timer for `floatingMenuAnchor`) | 1176; 2796 |
| `onEventManipulationPromotion` | `(Event, String?, Date, EventDragMode, CGPoint, CGRect) -> Void` | gesture promotes to move/resize | `handleTimelineManipulationPromotion` → resets menu, `setFocus(event, occurrenceID)` (enters focus) | 1177; 2770 |
| `onEventLongPressResolved` | `(CalendarEventLongPressResolution) -> Void` | gesture ends (no commit drag) | `handleTimelineLongPressResolved` → cancel pending menu; if no move and completed → `beginResizeGrace` + make menu interactive; if cancelled → `clearFocus` | 1178; 2811 |
| `onEventDragEnded` | `(Event, String?, Event.TimeRange, DragOffset, CGFloat) -> Void` | move drag commit | `handleTimelineEventDragEnded` → `handleEventDrag(...)` → **mutates store** (move / absorb / recurring-edit) + resize grace | 1179; 2833 / 3447 |
| `onEventResizeEnded` | `(Event, String?, Event.TimeRange, Date, EventDragMode, CGFloat) -> Void` | resize commit | `handleTimelineEventResizeEnded` → `handleEventResize(...)` → **mutates store** | 1180; 2844 / 3629 |
| `onCreateEvent` | `(Date, Event.TimeRange) -> Void` | drag-create gesture finishes | `handleTimelineCreateEvent` → `handleCreateEvent` → sets `pendingCreateTimeRange` (opens composer sheet; NO store write until save) | 1181; 2855 / 3729 |
| `onNonEventTap` | `() -> Void` | tap empty canvas | `handleTimelineNonEventTap` → reset menu, cancel grace, `clearFocus()` | 1182; 2859 |
| `onHourHeightCommit` | `() -> Void` | pinch gesture ends | `handleTimelineHourHeightCommit` → `calendarState.commitTimelineHourHeight()` (persists zoom) | 1183; 2866 |
| `onHorizontalScrollProgress` | `(TimelineHorizontalScrollProgress) -> Void` | horizontal scroll frames | `handleTimelineHorizontalScroll` → if interacting resets menu/grace; updates scroll-progress state | 1184; 2870 / 2405 |
| `onBoundaryExtensionStateChange` | `(TimelineBoundaryExtensionState) -> Void` | leading/trailing hour extension changes (cross-midnight drag) | `handleTimelineBoundaryExtensionStateChange` (2420) → updates `timelineBoundaryExtensionState` (fed back in as override) | 1185 |
| `onVisibleTimelineFrameChange` | `(CGRect) -> Void` | visible day frame (global coords) changes | `handleVisibleTimelineFrameChange` → stores `timelineVisibleDayFrameGlobal` (used for absorption hit-testing) | 1186; 2783 |
| `onPinchScrollAdjust` | `(CGFloat) -> Void` | pinch focal anchor requires scroll Y change | host closure → `verticalScrollPosition.scrollTo(point:)` (batched in disablesAnimations txn) | 1198; 2725 |

`TimelineDayView` exposes two extra callbacks that `TimelinePagerView` wires internally
(not at the host boundary, but a CALayer port must replicate them):
- `onCreationPreviewChanged: (Date, Event.TimeRange?) -> Void` (TLV 3083) — live
  drag-create preview updates `creationPreviewByDay` in the pager.
- `onHorizontalBoundaryPageRequest: (Int) -> Bool` (TLV 3085) — drag-at-edge requests a
  page turn; returns whether the page actually advanced.

### Output classification for the rewrite

- **Detail/sheet/menu navigation** (`onEventTap`, `onCreateEvent`, long-press family):
  mutate host UI `@State` only (routes, menus, focus) — never the store. Trivial to bridge.
- **Store-committing** (`onEventDragEnded`, `onEventResizeEnded`): the ONLY paths that
  write event data. Everything funnels through `handleEventDrag` / `handleEventResize`
  → `EventStore`. See §5.
- **Continuous geometry/scroll** (`onHorizontalScrollProgress`, `onPinchScrollAdjust`,
  `onVisibleTimelineFrameChange`, `onBoundaryExtensionStateChange`): high-frequency;
  the UIKit view will own these natively (it IS the scroll view) and call back only the
  derived state the host needs.

---

## 3. `EventDragState` — full field map (the shared scratchpad)

`@Observable final class EventDragState` — TimelineView **723–754**. Reference type,
created once in the host (`@State private var timelineDragState = EventDragState()`,
CalendarPageView 1032) and passed by reference into the pager. `@Observable` gives
**per-field dependency tracking**: only views that read a changed field re-render. This
is the single most performance-critical structure for the port — the UIKit side must
diff fields, not the whole object.

| Field | Type | Written by | Read by (re-renders on change) |
|---|---|---|---|
| `draggingEventID` | `UUID?` | `EventBlock.syncSharedDragStateForBegin` (EB 2434) / cleared (EB 974, TLV 980) | cross-day blocks (`isActiveDraggedOccurrence`, TLV 757), host gating (`timelineDragState.draggingEventID == nil`, CPV 1299/3167), absorb bubble visibility (CPV 1544) |
| `draggingOccurrenceID` | `String?` | EB 2435 / cleared 975 | which occurrence follows drag (TLV 763) |
| `draggingEvent` | `Event?` | EB 2436 / cleared 976 | preview rendering / drop logic |
| `draggingOriginalRange` | `Event.TimeRange?` | EB 2439 (`dragSourceRange ?? primaryTimeRange`) / cleared 977 | `previewRange(hourHeight:)` base (TLV 745) |
| `draggingRenderDayStart` | `Date?` | EB 2440 (`startOfDay(renderDayStart)`) / cleared 978 | cross-day projection of preview |
| `currentTouchPointGlobal` | `CGPoint?` | EB 2864/2875 (per touch frame) / cleared 979 | absorption spatial hit (TLV converts to day-local x; host reads for drop target, CPV 2028) |
| `dragOffset` | `DragOffset` | EB 2880 (**every drag frame**) / reset 981 | preview range computation (the hot path — only the dragged occurrence's block should track) |
| `dragMode` | `EventDragMode` | EB 2442 / onChange 2950 / reset 982 | move vs resizeTop vs resizeBottom rendering |
| `isHorizontalEdgeDragging` | `Bool` | EB 2940 / reset 983 | edge-page affordance |
| `isHorizontalAutoScrolling` | `Bool` | EB 2945 / reset 984 | auto-scroll-during-drag state |
| `dayColumnStep` | `CGFloat` | EB 2443 (`dragPreviewDayStep`) | horizontal day-offset math in preview |
| `currentDropTargetEventID` | `UUID?` | `TimelineDayView` spatial hit (TLV 3770/3773/4167) | `handleEventDrag` absorption parent resolution (CPV 3517); absorb-merge bubble |

Method: `previewRange(hourHeight:) -> Event.TimeRange?` (TLV 745) computes the live
preview from `draggingOriginalRange` + `dragOffset` + `dragMode` + `dayColumnStep` via
`calendarResolvedDragEditRange`. Reset helper: `calendarResetSharedEventDragState` (TLV 973).

**Write topology:** drag-begin sets the identity fields once (EB `syncSharedDragStateForBegin`);
`dragOffset` + `currentTouchPointGlobal` update every frame; `currentDropTargetEventID`
is written by the day view's spatial hit-test (it has overlap slots + day frame); all
fields clear on drag terminal (EB `clearSharedDragState` → `calendarResetSharedEventDragState`).

**Port implication:** in UIKit, `EventDragState` should remain a SwiftUI-observable
class (the host still reads `draggingEventID`/`currentDropTargetEventID` for the absorb
bubble + gating, and `onChange(of: timelineDragState.draggingEventID)` at CPV 1363).
The CALayer view writes the same fields; it must keep the same fine granularity so the
host's observers fire on the same edges. Internally the UIKit view will hold its OWN
plain-struct drag session (no SwiftUI tracking cost) and **mirror only the fields the
host observes** back into the shared `EventDragState`. The hot field `dragOffset` is the
risk point — see §7.

---

## 4. Host (`CalendarPageView`) state machine

The host @State block is CalendarPageView **985–1053**. Grouped by concern:

### 4a. Focus / selection
- `focusedEventID: UUID?` (1013), `focusedOccurrenceID: String?` (1014).
- Enter: `setFocus(event:occurrenceID:reason:)` (3096) — called from
  `handleTimelineManipulationPromotion` (drag/resize promotion) and after create
  (`handleCreatedEvent`).
- Exit: `clearFocus(reason:)` (3083) — called from tap-to-open-detail, non-event tap,
  cancelled manipulation, AND a self-healing guard: if the focused event leaves
  `canvasRenderableCalendarEvents` it auto-clears (CPV 1270, commit `7a12775`).
- `.onChange(of: focusedEventID/focusedOccurrenceID)` (1279/1289) logs only.
- Focus is **orthogonal to selection-for-detail**: detail is a separate route.

### 4b. Detail route
- `selectedEventDetailRoute: CalendarEventDetailRoute?` (994) drives
  `.navigationDestination(item:)` (1101). Set by `onEventTap`, by floating-menu actions
  (1479/1495), by detail-from-occurrence (1205/1208).
- `.onChange(of: selectedEventDetailRoute)` (1355) handles side effects.

### 4c. Floating menu (express long-press menu)
- `floatingMenuAnchor: CalendarEventLongPressBegan?` (997), `floatingMenuOccurrence`
  (998), `floatingMenuInteractive` (999), plus an arming task/token (1000/1001).
- Armed by `scheduleFloatingMenuActivation` (2879) after `onEventLongPressBegan`; a
  delay timer promotes `floatingMenuOccurrence` → visible `floatingMenuAnchor`.
- Resolved/dismissed in `handleTimelineLongPressResolved`, `resetFloatingMenuState`,
  `hideFloatingMenu` (2914). The overlay reads `floatingMenuAnchor` (1474).

### 4d. Create (composer) flow
- `pendingCreateTimeRange: PendingEventCreation?` (1006) drives `.sheet(item:)` (1171).
- Set by `handleCreateEvent` (3729). **No store write happens here** — the event only
  persists when the composer saves (`handleCreatedEvent` 3787 → `restartResizeGrace`).
- `previewCreation` prop (the ghost block) mirrors `pendingCreateTimeRange` into the
  timeline so the preview stays up while the sheet is open.

### 4e. Resize grace (post-commit fading handles)
- `resizeGraceState: CalendarResizeGraceState?` (1015) + occurrence context (1016) +
  fade/expiry tasks (1017/1018). Feeds the `graceResize*` props back into the pager.
- `beginResizeGrace` / `restartResizeGrace` / `cancelResizeGrace` — fired after a move/
  resize/create commit so the just-edited block keeps grabbable handles briefly.

### 4f. Live interrupt session
- `liveInterruptSession: CalendarInterruptLiveSession?` (1008). Struct = parentOccurrence
  + parentEventID + `parentEventSnapshot: Event` + title + typeTitle + `startedAt`
  (CalendarInterruptComposer 532). Identifiable + Equatable.
- Started at CPV 2970, stopped/cancelled at 2987/2999. Passed into the pager (input) so
  the live (red, ticking) interrupt bar renders inside the parent's geometry.
- `.onChange(of: liveInterruptSession == nil)` (1373) reacts to clear.

### 4g. Pure UI flags (sheets/overlays)
`isShowingDatePicker` (1009), `isShowingAgent` (1019), `isShowingSearch` (1020),
`isShowingShare` (1021), `showLongPressDeleteConfirm` (1002),
`showRecurrenceScopeDialog` (1005), plus their payload state. These are host-level
sheets — NOT part of the timeline surface; the CALayer view never touches them, but its
callbacks trigger them.

### 4h. Scroll / layout bridge state (host owns vertical scroll)
- `timelineVerticalScrollY` (1026), `timelineScrollViewportHeight` (1036),
  `verticalScrollPosition: ScrollPosition` (1033) — host owns the vertical ScrollView;
  feeds `verticalScrollY` in and applies `onPinchScrollAdjust` out.
- `timelineBoundaryExtensionState` / `timelineRawBoundaryExtensionState` (1034/1035) —
  cross-midnight hour extension, fed in as `boundaryExtensionStateOverride`.
- `isVerticallyScrolling` (1042) — phase flag driving `VerticalScrollGate` (CPV 77),
  the vertical analogue of `DayColumnGate` (freezes subtree body during scroll).
- `timelineVisibleDayFrameGlobal` (1043) — from `onVisibleTimelineFrameChange`.

---

## 5. EventStore mutation / commit paths

All event-data writes go through `EventStore` (`@MainActor`). The timeline NEVER mutates
data directly — it only fires `onEventDragEnded` / `onEventResizeEnded` / `onCreateEvent`.
The host handlers route to store methods.

### 5a. The published model
- `@Published var rawCalendarEvents: [Event]` (EventStore 56) — the underlying array,
  INCLUDES absorbed todos. Sync / restore / lookup / mutate read this directly.
- `var canvasRenderableCalendarEvents` (72) — computed filter
  `rawCalendarEvents.filter { $0.absorbedIntoEventID == nil }`. **Everything that
  renders on the canvas reads this** (the deliberate split from the
  `canvasRenderable` audit; raw vs renderable is compile-time enforced).
- `@Published private(set) var dominoTickNonce: Int` (63) — opaque bump for horizon
  drift; consumers re-read via observation, value irrelevant.
- `@Published var events: [Event]` (45) — separate todo/event list (not the calendar
  canvas array).

### 5b. Mutation primitives
- `mutateCalendarEvent(id:_:) -> Bool` (561) — in-place transform on `rawCalendarEvents`.
- `updateCalendarEvent(_:)` (709) — replace whole event by id → `saveCalendarEvents(refreshInterrupts: true)` → fires `onCalendarEventRecordCompleted` + `calendarEventRecorded`.
- `addCalendarEvent(_:)` (702), `deleteCalendarEvent(_:)` (720, with absorption-release + interrupt-orphan sweeps).
- `saveCalendarEvents(refreshInterrupts:)` (536) → optional `refreshInterruptRelationStates` → private `saveCalendarEvents()` (364): JSON-encode to `defaults` + `syncWidgetSnapshots()` (WidgetKit reload). **This is the persistence + side-effect tail of every write.**

### 5c. Drag commit — `handleEventDrag` (CalendarPageView 3447)
Computes `newRange` from `draggedRange` + day-offset + Y offset. Three branches:
1. **Absorption** (3508): `.todo`, non-recurring, ≥10pt motion, and a parent `.event`
   under the drop (preferring `timelineDragState.currentDropTargetEventID` 3517, falling
   back to time-overlap 3521). → commit move via `updateCalendarEvent` FIRST, THEN
   `store.absorbTodoIntoEvent(todoID:parentEventID:)` (3549). Absorb sends
   `calendarTodoAbsorbed` (EventStore 114).
2. **Recurring series** (3555): `store.applyRecurringEdit(seriesEvent:occurrenceDate:scope:.single)`
   (3557 → EventStore 750) creates a single-occurrence exception, never mutating the
   series template. Then resize-grace on the moved exception.
3. **Plain move** (3599): rebuild ranges (`calendarUpdatedRangesAfterDrop`, preserving
   non-dragged ranges) → `updateCalendarEvent(updated)` → `restartResizeGrace`.

### 5d. Resize commit — `handleEventResize` (3629)
Parallel structure: recurring → `applyRecurringEdit`; plain → `updateCalendarEvent`.

### 5e. Create commit
`handleCreateEvent` (3729) does NOT write — only opens the composer. The composer's save
path calls `store.addCalendarEvent` and the completion lands in `handleCreatedEvent`
(3787). Interrupts go through `store.createInterrupt` (createInterruptEvent 3767).

### 5f. Recurring-edit invariant
Any code path that moves/resizes/deletes an event MUST funnel recurring series through
`applyRecurringEdit` / `deleteRecurringCalendarEvent`, never raw `updateCalendarEvent` on
the series (per MEMORY recurring-events audit). The CALayer port does not change this —
it still emits `onEventDragEnded` and the host's existing branching handles recurrence.

### 5g. Sync guards (loop avoidance — §7)
There is no in-flight `isSyncing` flag inside these calendar mutations; the loop guard
lives at the host: cache rebuild is gated and pinch writes are batched. See §7.

---

## 6. Occurrence injection & `timelineVisibleOccurrences` filtering

### 6a. Per-offset injection
`occurrencesForOffset: (Int) -> [EventOccurrence]` is the data pipe. Host wires
`{ occurrencesCache[$0] ?? [] }` (CPV 2688). Cache build:
- `rebuildOccurrencesCache()` (CPV 3197): reads `store.canvasRenderableCalendarEvents`
  (3198 — the **absorbed-filtered** list), computes a synchronous urgent window
  (`center ± 7`) via `CalendarLayout.occurrencesForDate` + `allDayOccurrencesForDate`,
  then progressively fills the rest of `dayRange` off the run loop (3217).
- Triggers: `.onChange(of: store.rawCalendarEvents)` (1260), day-change /
  becomeActive (1252/1255), dayRange expansion (`rebuildOccurrencesCacheIncremental`
  1361, **safe only because dayRange monotonically expands**), timer-event tick (3308),
  visible-days fill (3325).

### 6b. Per-day visible filtering (inside the day view)
`TimelineDayView` caches its layout (`cachedVisibleOccurrences` 3105, `cachedOverlapSlots`,
interrupt lookups) and recomputes ONLY on `.onChange(of: occurrences)` (TLV 4143 →
`refreshCachedLayout` → assigns `cachedVisibleOccurrences` at 4806). During scroll the
data is unchanged, so the body reads cached results instead of recomputing overlap/
interrupt layout each frame (TLV 3523: `guard needsLiveLayout else { return cachedVisibleOccurrences }`).
- `isInVisibleViewport: Bool` (TLV 3090) gates drag-preview computation for off-screen
  days (`calendarIsDayInVisibleViewport`, TLV 2374); off-screen days skip `dragOffset`
  tracking (early return TLV 3314).

**Port implication:** the CALayer view is the natural home for both layers — it pulls
occurrences per offset via the injected closure and caches the overlap/interrupt layout
internally, invalidating only when the offset's occurrence array identity changes
(matching the existing `.onChange(of: occurrences)` edge).

---

## 7. Two-way bindings & loop-avoidance

Three `@Binding`s cross the boundary: `hourHeight`, `selectedDayOffset`, `rangeMode`
(TLV 1154–1156). Loop avoidance:

1. **`hourHeight` (pinch).** Wrapped binding read/write `calendarState.timelineHourHeight`
   (host 2680). Pinch writes `hourHeight` AND requests a scroll-Y change via
   `onPinchScrollAdjust`; the host batches both in a `disablesAnimations` transaction
   (CPV 2725 comment) so scale + scroll land in ONE render pass — no oscillation. The
   `liveHourHeight` ref-box lets `EventBlock` read the live value without taking a
   per-frame-invalidating stored prop. `onHourHeightCommit` persists once at gesture end.
   Prior hazard: per-frame `applyDynamicPinchMin` caused a first-pinch hang
   (`lastDynamicPinchMinInputs` 1037 memoizes it; commit `2b4ac58`).
2. **`selectedDayOffset` (paging).** Host owns it; the pager updates on user scroll and
   reads it back to center. Scroll-restore guards (`isRestoringScroll`,
   `isUserScrollUpdating`, `pendingScrollTarget`, TLV 1344–1346) prevent
   programmatic-scroll ↔ user-scroll feedback.
3. **`rangeMode`.** Low-frequency; the pager is rebuilt via `.id(rebuildKey)` (CPV 2735)
   on range change to avoid stale TabView pages.

**`EventDragState` is the loop-sensitive shared object.** It is written by the gesture
layer and read by the host. To avoid a write→observe→re-render→re-measure cycle the host
only observes coarse edges (`onChange(of: timelineDragState.draggingEventID)`, CPV 1363,
nil↔non-nil) — NOT the per-frame `dragOffset`. The `@Observable` granularity guarantees
that updating `dragOffset` does NOT invalidate host views that only read
`draggingEventID`. **This is the single trickiest state-bridging risk for the rewrite:**
a naive UIKit port that pushes `dragOffset` into an `@Published`/ObservableObject (rather
than `@Observable` field-level tracking) will invalidate the whole host body 60×/s and
tank drag perf. The port MUST keep the drag session in plain UIKit state and mirror only
the coarse fields (`draggingEventID`, `currentDropTargetEventID`, `dragMode`) back into
the SwiftUI-observed `EventDragState`, leaving `dragOffset` either unobserved by SwiftUI
or confined to the leaf the UIKit view itself owns.

Cache-rebuild guards: `.onChange(of: store.rawCalendarEvents)` rebuilds the cache, but
cache reads during interaction are frozen by `VerticalScrollGate` (CPV 77) and
`DayColumnGate` (TLV 426) — `Equatable` view wrappers that short-circuit body
re-evaluation while scrolling. Several handlers no-op while dragging
(`timelineDragState.draggingEventID == nil` guards, CPV 1299/3167) so a commit doesn't
reshuffle data mid-gesture.

---

## 8. Contract summary (the UIViewRepresentable boundary)

**INPUTS to inject / observe (≈30):** 6 data (occurrences closure ×3, dayRange,
daysCount, liveInterruptSession) + 11 layout/zoom (incl. 3 vertical-scroll metrics) +
~10 focus/preview/grace highlight props + 1 shared `EventDragState`. Of these, 3 are
two-way `@Binding` (hourHeight, selectedDayOffset, rangeMode); the rest one-way.

**OUTPUTS / callbacks to call (13 at the pager boundary + 2 internal day-level):**
- 2 store-committing: `onEventDragEnded`, `onEventResizeEnded`.
- 5 navigation/UI: `onEventTap`, `onCreateEvent`, `onEventLongPressBegan`,
  `onEventManipulationPromotion`, `onEventLongPressResolved`, `onNonEventTap`.
- 6 continuous geometry/scroll: `onHourHeightCommit`, `onHorizontalScrollProgress`,
  `onBoundaryExtensionStateChange`, `onVisibleTimelineFrameChange`, `onPinchScrollAdjust`.
- Internal: `onCreationPreviewChanged`, `onHorizontalBoundaryPageRequest`.

**Shared mutable bridge:** `EventDragState` (12 fields) — written by gesture layer, read
by host; keep `@Observable` field granularity; do NOT route `dragOffset` through coarse
publishing.

**Store side (unchanged by the port):** all writes via `EventStore.updateCalendarEvent`
/ `addCalendarEvent` / `absorbTodoIntoEvent` / `applyRecurringEdit`, persisted through
`saveCalendarEvents(refreshInterrupts:)`; canvas reads `canvasRenderableCalendarEvents`
(absorbed-filtered). The host's `occurrencesCache` is the derived layer the UIKit view
pulls from via `occurrencesForOffset`.
