# Gesture & Interaction Parity Spec

Baseline for the UIKit+CALayer rewrite of the SwiftUI calendar timeline. Every numbered item (`G-n`) is a parity checkpoint: the rewrite must reproduce the exact behavior, threshold, timing, and callback firing described. File:line refs are against the current tree.

Primary sources:
- `Done/Views/Calendar/Components/Timeline/Event/EventBlock.swift` — `EventBlockDragGesture` (UIViewRepresentable, line 1107), `Coordinator` (line 1237), `ExtendedHitAreaView` (line 1067), pure helpers (lines 24–218, 838–1064).
- `Done/Views/Calendar/Components/Timeline/TimelineView.swift` — `CreationDragGesture` (line 2761), `PinchScrollCoordinator` (line 994), `MagnificationGesture` pinch (line 1583), absorption drop-target (line 3658), boundary paging (line 1846).
- `Done/Views/Calendar/Components/Timeline/TimelineEditMapping.swift` — drag→time mapping (lines 309–384).
- `Done/Views/Calendar/CalendarEventDetailTypes.swift:95` — promotion gate.
- `Done/Views/Calendar/CalendarPageView.swift` — drag/long-press handlers (lines 2770–2921, 3447+).

---

## 0. Shared constants & enums (lock these exact values)

| Symbol | Value | Loc |
|---|---|---|
| `calendarEventManipulationLongPressDuration` | `0.35` s | EventBlock.swift:1095 |
| `calendarEventExpressMenuLongPressDuration` | `1.0` s | EventBlock.swift:1096 |
| express-menu extra hold (`activationDelay`) | `1.0 − 0.35 = 0.65` s | EventBlock.swift:1098 / CalendarPageView:1081 |
| `CreationDragGesture.minimumPressDuration` (wired) | `0.5` s | TimelineView.swift:4197 (struct default `0.25`, line 2762) |
| movement-promotion threshold (move/resize drag) | `hypot(dx,dy) > 8` pt (window coords) | EventBlock.swift:1386 |
| creation activation threshold | `creationActivationThreshold = 18` pt (deltaY from start) | TimelineView.swift:3224, 4218 |
| `edgeThreshold` (resize) | `10` pt (struct default, EventBlock.swift:1109); coordinator field default `20` (line 1247) — **runtime value is 10**, set via `updateUIView` (line 1217) |
| scaled resize threshold | `min(edgeThreshold, max(8, viewHeight*0.2))` | EventBlock.swift:45 |
| `resizeMinHeight` (block must be ≥ this to allow resize) | `32` pt | EventBlock.swift:11 |
| resize handle hit margin | `±12` pt around handle capsule | EventBlock.swift:54 |
| handle capsule width | `min(viewWidth*0.4, 36)` | EventBlock.swift:53, 858 |
| `verticalEdgeInset` (fall-through band) | `6` pt when no resize handles, else `0` | EventBlock.swift:2837, 2843 |
| fall-through collapse / full heights | `12` / `32` pt (smoothstep between) | EventBlock.swift:997–998 |
| 15-min snap size | `hourHeight / 4` | EventBlock.swift:2363; TimelineEditMapping:367,376 |
| move snap interval | `15*60` s (`calendarPreviewOffsetSeconds`) | TimelineView.swift:206 |
| resize min height during drag | `20` pt (`resizeHeight`) | EventBlock.swift:2374 |
| resizeTop Y-offset min block height | `hourHeight / 2` | EventBlock.swift:2421 |
| min created-event duration | `15*60` s | TimelineView.swift:4234 |
| `calendarHorizontalAutoScrollEdgeInsetDefault` | `32` pt | EventBlock.swift:24 |
| `calendarVerticalAutoScrollEdgeInsetDefault` | `192` pt | EventBlock.swift:25 |
| `calendarMaxAutoScrollSpeedDefault` | `1200` pt/s | EventBlock.swift:26 |
| `calendarAutoScrollCurveExponent` | `1.5` | EventBlock.swift:27 |
| `calendarAutoScrollSafeMargin` | `80` pt | EventBlock.swift:67 |
| horizontal boundary page min interval | `0.8` s | EventBlock.swift:1284 |
| `hourHeight` min / max | `12` / `96` pt | CalendarViewState.swift:17–18 |
| pinch boundary threshold / saturation / follow | `0.04` / `0.28` / `0.35` | TimelineView.swift:1567–1569 |
| adjacent-event snap threshold | `8` pt | TimelineView.swift:3225 |
| absorption drop displacement gate | `|offset.x|>10 || |offset.y|>10` pt | CalendarPageView.swift:3510 |
| CADisplayLink frame range (both gestures) | `CAFrameRateRange(min:80, max:120, preferred:120)` | EventBlock.swift:1740; TimelineView.swift:2907 |

`EventDragMode = { .move, .resizeTop, .resizeBottom }` (EventBlock.swift:943). `EventDragTerminalState = { .completed (.ended), .cancelled (.cancelled/.failed) }` (EventBlock.swift:949, 954).

---

## 1. Event move / resize drag — `EventBlockDragGesture`

The single `UILongPressGestureRecognizer` (subclass `TracingLongPressGesture`) drives **all three** modes. Mode is decided once at `.began` from touch position; it never changes mid-drag.

### 1.1 Recognizer setup & hit area
- **G-1** Recognizer is a `TracingLongPressGesture : UILongPressGestureRecognizer`, `minimumPressDuration = 0.35` s, `delegate = coordinator`, attached to an `ExtendedHitAreaView` (EventBlock.swift:1186–1192). One gesture per block; created in `makeUIView` (line 1175).
- **G-2** The gesture overlay is only present when `isDragEnabled && !isPinchActive` (EventBlock.swift:2841). `isDragEnabled = onDragEnded != nil || onResizeTopEnded != nil || onResizeBottomEnded != nil` (line 2359). During pinch the entire overlay is removed (no drag possible while pinching).
- **G-3** `ExtendedHitAreaView.hitTest` returns `self` whenever `point(inside:)` is true, so the touch view is the hit-area view, **not** the SwiftUI content underneath — this is what lets the gesture survive SwiftUI content rebuilds mid-drag (EventBlock.swift:1082–1092).
- **G-4** `point(inside:)` → `calendarExtendedHitAreaContains` (EventBlock.swift:1011). Three-stage test:
  1. Expand bounds by `verticalExtension` (= `outerEdgeThreshold`, default `0`) vertically; point must be inside expanded bounds.
  2. Inward fall-through inset = `calendarFallThroughEdgeInset(maxInset: verticalEdgeInset, height: bounds.height)` — smoothstep: `0` below 12pt, full `verticalEdgeInset` (6) above 32pt, `maxInset * (t²(3−2t))` between (EventBlock.swift:1000–1009). If point is inside the top/bottom inset band, **fail** (touch falls through to day column creation layer).
  3. Point must not be inside any `excludedHitRects` (compound-interrupt cutouts, EventBlock.swift:2636).
- **G-5** The SwiftUI `.contentShape(CalendarEventBlockInteractionShape(...))` (EventBlock.swift:2833) mirrors the same `calendarFallThroughEdgeInset` so the tap gesture's hit area matches the UIView's — both must shrink in lockstep or edge-band touches break (EventBlock.swift:2051–2078). Rewrite must keep tap + drag hit areas identical.

### 1.2 `.began` (EventBlock.swift:1326–1379)
- **G-6** Capture `initialPointInWindow = gesture.location(in: nil)` and seed `lastLocationInWindow`. Reset all per-drag state: `autoScrollCompensation{X,Y}=0`, `autoScrollVelocity{X,Y}=0`, `isHorizontalSnapSuppressed=false`, `hasMovedAfterLongPress=false`, `hasPromotedManipulation=false`, `lastSnappedStep=0`, `horizontalBoundaryPageCount=0`, `horizontalBoundaryPageOriginX=initialPointInWindow.x`.
- **G-7** `findScrollTargets(startingAt: view)` walks the superview chain; picks the **first** ancestor `UIScrollView` with `isScrollEnabled` and `contentSize.width-bounds.width > 1` as horizontal, and likewise `>1` for vertical (EventBlock.swift:1958–1983). The two may be the same scroll view (handled specially in tick).
- **G-8** `currentMode = calendarResolveDragMode(...)` decided ONCE here. Logic (EventBlock.swift:31–61):
  - if `viewHeight < resizeMinHeight (32)` → `.move`.
  - `scaledThreshold = min(edgeThreshold(10), max(8, viewHeight*0.2))`.
  - `inTopEdge = locationY < scaledThreshold && canResizeTop`; `inBottomEdge = locationY > viewHeight − scaledThreshold && canResizeBottom`.
  - if neither edge → `.move`.
  - else require touch X within `[centerX − handleWidth/2 − 12, centerX + handleWidth/2 + 12]` (handle capsule + 12pt margin); outside → `.move`.
  - else `.resizeTop` / `.resizeBottom`.
- **G-9** Fires `onLongPressBegan?(mode, initialPointInWindow, viewFrameInWindow)` (line 1358). `viewFrameInWindow = view.convert(view.bounds, to: nil)` (line 1289–1292). Also `UIImpactFeedbackGenerator(style: .medium).impactOccurred()` (line 1359). NOTE: this haptic is a **fresh** generator each time (medium), distinct from the per-snap `.light` generator.
- **G-10** Consumer (`EventBlock.onLongPressBegan`, EventBlock.swift:2856): wraps in `withAnimation(.easeOut(0.15))` setting `isLongPressing=true; dragMode=mode`, then forwards up to `handleTimelineLongPressBegan` (CalendarPageView:2796) which schedules the floating menu (see §6).

### 1.3 `.changed` — promotion gate (EventBlock.swift:1381–1446)
- **G-11** Compute raw window delta and `hasCrossedMovementThreshold = hypot(dx,dy) > 8`.
- **G-12** Until promoted: `calendarShouldPromoteLongPressToManipulation(dragMode, canMove, movementExceededThreshold)` (CalendarEventDetailTypes.swift:95) gates promotion — requires `movementExceededThreshold` AND (`.move` ⇒ `canMove`; resize ⇒ always true). If not satisfied, `stopAutoScroll` and return (staged long-press, no movement applied yet).
- **G-13** On first promotion (EventBlock.swift:1398–1414): set `hasMovedAfterLongPress=true`, `hasPromotedManipulation=true`, set `TracingLongPressGesture.isDragPromoted=true` (absorbs SwiftUI rebuild touch-cancels — see G-30), call `disableScrollPanGesturesForDrag()`, write bindings `dragMode=mode; isHorizontalEdgeDragging=false; isHorizontalAutoScrolling=false; isDragging=true`, fire `onManipulationPromotion?` then `onDragBegan?`, then `updateAutoScrollVelocity()` and an immediate `updateDragOffset` (so frame 0 already reflects finger — no zero-frame lag). Return.
- **G-14** After promotion every `.changed`: if `hasMovedAfterLongPress` → `updateAutoScrollVelocity()` first, else `stopAutoScroll`. Then `updateDragOffset(using:)`. Throttled debug log at ≥0.08s.
- **G-15** Callback order at promotion: `onManipulationPromotion` (EventBlock consumer sets `dragState.currentTouchPointGlobal` then forwards to `handleTimelineManipulationPromotion` → `resetFloatingMenuState()` + `setFocus(...)`, CalendarPageView:2770) → `onDragBegan` (consumer calls `syncSharedDragStateForBegin`, EventBlock.swift:2426 — writes `dragState.draggingEventID/OccurrenceID/Event/OriginalRange/RenderDayStart/dragMode/dayColumnStep`).

### 1.4 Drag offset math (EventBlock.swift:1574–1643)
- **G-16** `updateDragOffset`: `locationInWindow = gesture.location(in: nil)`; fire `onDragTouchChanged?(locationInWindow)` (consumer sets `dragState.currentTouchPointGlobal`, used by absorption hit-test §5).
- **G-17** Finger delta X is special-cased for **single-day boundary paging** (`currentMode == .move && usesHorizontalBoundaryPaging && horizontalAutoScrollUnitStep > 0`): `localOffsetX = location.x − horizontalBoundaryPageOriginX`, then `calendarBoundaryPagedHorizontalDragOffset = pageCount*dayStep + localOffsetX` (EventBlock.swift:138–145, 1579–1591). Otherwise X delta = `location.x − initialPointInWindow.x`.
- **G-18** Compose: `offset = fingerDelta + autoScrollCompensation` (`calendarComposedDragOffset`, line 125). Compensation is the explicit scroll-offset delta accumulated by auto-scroll ticks — NOT implicit content-offset reads.
- **G-19** `applyDragOffset` (line 1606): `suppressHorizontalSnap = isHorizontalSnapSuppressed || autoScrollVelocityX != 0`. `calendarResolvedDragOffset` (line 191): for non-move → `(x:0, y)`; for move → X = `calendarMoveOffsetX` (line 149): if `suppressSnap` returns raw X, else snaps to nearest day column: `round(offsetX/dayColumnStep)*dayColumnStep`.
- **G-20** Y clamp: `calendarClampedMoveDragOffsetY` (line 211) — only for `.move`, clamps Y to `verticalDragBounds` (the visible extended-timeline window). Resize Y is unclamped here (resize clamps later in `resizeHeight`/`resizeYOffset`).
- **G-21** Per-snap haptic: if `snapSize > 0`, `currentStep = round(resolved.y / snapSize)`; on step change fire the reused `impactFeedback` (`.light`) and update `lastSnappedStep` (EventBlock.swift:1620–1627). Note: snap haptic fires off raw resolved Y at 15-min boundaries for ALL modes (move included), independent of the actual time-snap applied downstream.
- **G-22** Write-back: only if `parent.dragOffset != resolved` (dedupe), then `parent.dragOffset = resolved` and `onDragChanged?(resolved)` (consumer writes `dragState.dragOffset = offset` immediately, EventBlock.swift:2877 — avoids one-frame onChange lag).

### 1.5 Drag→time mapping (downstream, `calendarResolvedDragEditRange`, TimelineEditMapping.swift:331)
- **G-23** `.move`: `rawOffsetSeconds = dragOffset.y/hourHeight*3600`; snapped via `calendarPreviewOffsetSeconds` (15-min, but reverts to raw if snapping would cross a different day boundary than the finger — TimelineView.swift:203–233). Horizontal day shift = `round(dragOffset.x/dayColumnStep)` days added via `Calendar.date(byAdding:.day)`.
- **G-24** `.resizeTop`: `snappedYOffset = round(dragOffset.y/(hourHeight/4))*(hourHeight/4)`; new start = `start + snappedYOffset/hourHeight*3600`; guard `newStart < range.end` else unchanged.
- **G-25** `.resizeBottom`: same snap; new end = `end + offsetSeconds`; guard `newEnd > range.start` else unchanged.
- **G-26** Visual during resize (EventBlock.swift:2371–2424): `resizeHeight` clamps to ≥20pt; `resizeYOffset` (resizeTop only) = `min(snappedResizeOffset, baseHeight − hourHeight/2)`. The block's `.offset(y:)` is applied only for resize modes; move Y is rendered via the day view's `adjustedRange` (not block offset). Move X is rendered via block `.offset(x: moveOffsetX)` (line 2831).

### 1.6 `.ended / .cancelled / .failed` (EventBlock.swift:1448–1516)
- **G-27** `terminalState = calendarDragTerminalState(state)`: `.ended→.completed`, `.cancelled/.failed→.cancelled`, else nil (return).
- **G-28** If `hasPromotedManipulation`: `shouldForwardDrop = (terminalState == .completed)`; one final `updateDragOffset`; capture `finalOffset = parent.dragOffset`; `DragSessionMonitor.endSession()`; `finalizeTouchInteraction()`. Then if `shouldForwardDrop && hadMovedAfterLongPress` fire `onDragEnded?(mode, finalOffset)`. Always fire `onLongPressResolved?(mode, terminal, hadMoved, lastLocationInWindow)` then `onDragTerminal?(mode, finalOffset, terminal)`.
  - `onDragEnded` consumer (EventBlock.swift:2882): dispatches by mode to `onDragEnded?` (move) / `onResizeTopEnded?(offset.y)` / `onResizeBottomEnded?(offset.y)`.
  - `onDragTerminal` consumer (line 2892): `isLongPressing=false; clearSharedDragState()` (resets entire `EventDragState`).
- **G-29** If NOT promoted (pure long-press, no move past 8pt): `finalizeTouchInteraction()`, fire `onLongPressResolved?(mode, terminal, false, lastLocationInWindow)`. Consumer (`handleTimelineLongPressResolved`, CalendarPageView:2811): on `.completed` non-move begins resize grace + makes floating menu interactive; on `.cancelled` clears focus + hides menu.
- **G-30** `TracingLongPressGesture.touchesCancelled` (line 1164): if `isDragPromoted` → log + **swallow** (don't forward to super) so SwiftUI view rebuilds can't cancel an active drag; else forward to super.

### 1.7 `finalizeTouchInteraction` & `deinit` recovery
- **G-31** `finalizeTouchInteraction` (EventBlock.swift:1549): stops auto-scroll, clears `isDragPromoted`, `restoreScrollPanGestures()`, nils `activeGesture`/scroll views, resets `hasMovedAfterLongPress`/`hasPromotedManipulation`/`isHorizontalSnapSuppressed`, writes all bindings to false/zero, resets compensation + boundary-page state.
- **G-32** `deinit` (line 1523): if `calendarDragGestureNeedsTerminalRecovery(...)` (any of: active gesture, isDragging, hasMoved, promoted, nonzero offset, edge-dragging, autoscrolling — line 1038) → synthesize a `.cancelled` terminal: fire `onLongPressResolved(.cancelled)` + `onDragTerminal(.cancelled)` and reset bindings. This is the safety net for coordinator destruction mid-drag (e.g. LazyHStack recycling). **Rewrite must reproduce this recovery path.**

### 1.8 Scroll-gesture suppression during drag
- **G-33** `disableScrollPanGesturesForDrag` (line 1896): walks the **entire** ancestor chain; for each unique `UIScrollView` saves & sets `canCancelContentTouches=false` and disables ALL its gesture recognizers (`isEnabled=false`). Restored in `restoreScrollPanGestures` (line 1919). This prevents scroll views from stealing/cancelling the touch during drag.
- **G-34** Delegate `gestureRecognizer(_:shouldRecognizeSimultaneouslyWith:)` returns `hasPromotedManipulation` (line 1996) — only coexist with other recognizers AFTER promotion (so nothing can cancel an active drag), but before promotion it stays exclusive.

---

## 2. Edge auto-scroll (event drag) — `Coordinator` + `CADisplayLink`

- **G-35** `updateAutoScrollVelocity` (EventBlock.swift:1650): gate on `hasMovedAfterLongPress` (else stop + clear edge flags). `horizontalEdgeActive = isInHorizontalAutoScrollEdgeZone()`.
- **G-36** Horizontal branch: if `.move && usesHorizontalBoundaryPaging` → `autoScrollVelocityX=0` and call `handleHorizontalBoundaryPagingIfNeeded` (single-day paging). Else `autoScrollVelocityX = (.move ? autoScrollVelocity(horizontalScrollView,.horizontal) : 0)`. Vertical always `autoScrollVelocity(verticalScrollView,.vertical)`.
- **G-37** `calendarAutoScrollVelocity` curve (EventBlock.swift:69–113):
  - `effectiveInset = min(max(edgeInset,0), viewportLength*0.48)`; if 0 → velocity 0.
  - Past `calendarAutoScrollSafeMargin (80pt)` from either edge → immediate `±maxSpeed` (so finger never enters system gesture zones).
  - Within `effectiveInset` but outside safe margin: `progress = (effectiveInset − loc)/effectiveInset` (or symmetric for bottom/right); `scaledProgress = progress^1.5`; velocity = `±maxSpeed * scaledProgress`.
  - Boundary clamp: when content scrollable (`maxOffset−minOffset>1`), zero velocity if at min and pushing further min, or at max pushing further max.
- **G-38** Display link lifecycle: `startAutoScroll` (line 1736) creates the `CADisplayLink` (80–120fps) once; `stopAutoScroll(reason:)` (line 1755) invalidates + zeroes velocities + clears `isHorizontalAutoScrolling`. Kept alive if `needsBoundaryPagingTick = usesHorizontalBoundaryPaging && horizontalEdgeActive` even at zero velocity (line 1674).
- **G-39** `handleAutoScrollTick` (line 1782): `dt = max(targetTimestamp − timestamp, 0)`; `deltaX = velocityX*dt`, `deltaY = velocityY*dt`. If horizontal and vertical scroll views are the **same object**, apply combined delta once; else apply per-axis separately. `applyAutoScroll` (line 1931) clamps to scroll-view content bounds and `setContentOffset(_, animated:false)`, returns the actually-applied delta which is **accumulated into `autoScrollCompensation{X,Y}`**. Then refresh `lastLocationInWindow` from the gesture, re-run `updateAutoScrollVelocity`, re-run `updateDragOffset` (so the dragged time keeps advancing while finger sits at edge).
- **G-40** `locationInViewport(scrollView, axis)` = `lastLocationInWindow.{x|y} − scrollView.convert(bounds, to:nil).min{X|Y}` (line 1864). Window↔view transform; rewrite must use the same reference frame.
- **G-41** Edge flags: `isHorizontalSnapSuppressed = horizontalEdgeActive || (velocityX != 0)`; `parent.isHorizontalEdgeDragging = isHorizontalSnapSuppressed`; `parent.isHorizontalAutoScrolling = (velocityX != 0)` (line 1680–1684). These feed back into `dragState` (EventBlock.swift:2938–2946) only while `isDragging`, and gate the absorption highlight (§5) and snap suppression.

---

## 3. Single-day horizontal boundary paging

- **G-42** Active only when `dayColumnStep <= 0 && dragPreviewDayStep > 0` (single-day mode: `columnStep=0`, `previewDayStep=width+daySpacing`, TimelineView.swift:2267–2268) → sets `usesHorizontalBoundaryPaging=true` (EventBlock.swift:2846).
- **G-43** `handleHorizontalBoundaryPagingIfNeeded` (EventBlock.swift:1701): require `horizontalEdgeActive`, `unitStep>0`, callback present, `direction = horizontalBoundaryPageDirection() ≠ 0` (−1 left edge / +1 right edge, `calendarHorizontalBoundaryPageDirection`, line 176). Rate-limited: `now − lastHorizontalBoundaryPageTimestamp ≥ 0.8s`. Call `onHorizontalBoundaryPageRequest(direction)`; if it returns true, `lastTimestamp=now`, `horizontalBoundaryPageCount += direction`, `horizontalBoundaryPageOriginX = lastLocationInWindow.x`, then immediately `updateDragOffset` (so preview jumps to new day even if finger stationary).
- **G-44** `requestHorizontalBoundaryPage` (TimelineView.swift:1846): only `daysCount==1`; computes `selectedDayOffset+direction`, clamps via `calendarTimelineResolvedCenteredDayOffset(deferOutOfRangeSelection:false)`; if changed sets `selectedDayOffset` and returns true (commits the page turn).
- **G-45** Offset accumulation: `calendarBoundaryPagedHorizontalDragOffset = pageCount*dayStep + localOffsetX` (line 138) — adds committed page turns on top of finger's local X within current page (distinct from auto-scroll compensation which would double-count). Downstream day shift via `calendarDayOffsetFromHorizontalDrag(round(offsetX/dayColumnStep))` (TimelineEditMapping:386).

---

## 4. Drag-to-create — `CreationDragGesture` (TimelineView.swift:2761)

- **G-46** Two recognizers on a plain `UIView`: a `UILongPressGestureRecognizer` (`minimumPressDuration=0.5` as wired, struct default 0.25) + a `UITapGestureRecognizer`. Delegate returns `shouldRecognizeSimultaneouslyWith = false` (line 2869) — exclusive (no coexistence). Layer sits beneath events (events' `verticalEdgeInset` fall-through hands edge-band touches here).
- **G-47** `.began` (line 2841): `activeGesture=gesture; verticalScrollView=findVerticalScrollTarget(...)` (first scrollable ancestor with vertical range >1, line 2987); `onBegan?(location.y)`. Consumer (TimelineView.swift:4202): `isLongPressingCreation=true; isCreating=false; creationStartY=y; creationCurrentY=y; lastTickMinutes=−1`; prepare snap haptic; fire `hapticFeedback.impactOccurred()`.
- **G-48** `.changed` (line 2846): `onChanged?(location.y)` + `updateAutoScrollVelocity()`. Consumer (line 4213): set `creationCurrentY=y`. If not yet `isCreating`: `deltaY=y−creationStartY`; `calendarShouldActivateCreationAfterLongPress(deltaY, threshold:18)` → if exceeded set `isCreating=true`, seed `lastTickMinutes`, fire activation haptic, return. Once creating: `checkHapticTick()` (per-minute-change haptic, line 4411) + `checkAdjacentSnapHaptic()` (line 4421).
- **G-49** Preview range (`creationPreviewRange`, line 4263): start/end times via `timeFromYWithAdjacentSnap(creationStartY|creationCurrentY)`; ordered so start<end. Rendered by `creationPreview` (line 4360): rounded rect (corner 10, or 2 if zero-duration), fill `currentTimeIndicatorColor.opacity(0.15)`, stroke `0.6/2pt`, `previewTextStack(title:L(.newEvent))`, `.allowsHitTesting(false)`.
- **G-50** `timeFromY` → `calendarTimelineDateFromYPosition(y, headerHeight, hourHeight, leading/trailingExtendedHours, snapMinutes)` (line 4394). Grid snap = `snapMinutes`. Adjacent-event magnetic snap layered on top (§4.1).
- **G-51** `.ended` (line 2849): `stopAutoScroll`; nil gesture/scroll view; `onEnded?(location.y)`. Consumer (line 4231): if `isCreating && creationPreviewRange != nil` enforce min duration 15min (`end = start+900s` if shorter), fire `onCreateEvent?(finalRange)` → `handleCreateEvent`. Reset all creation state.
- **G-52** `.cancelled/.failed` (line 2854): `stopAutoScroll`; `onCancelled?()` (line 4253) resets creation state (no event created).
- **G-53** Tap (line 2864): `handleTap` on `.ended` → `onTap?()` → consumer `onNonEventTap?()` → `handleTimelineNonEventTap` (resets menu, clears focus). This is the empty-space deselect.
- **G-54** Creation auto-scroll (TimelineView.swift:2890–2965): identical curve (`calendarAutoScrollVelocity`) but **vertical-only**, gated by `isAutoScrollEnabled` (= `isCreating`, line 4198). Tick calls `onChanged?(gesture.location.y)` after applying scroll so the preview extends. `setAutoScrollEnabled` toggles based on `isCreating` each `updateUIView` (line 2802).

### 4.1 Adjacent-event magnetic snap (creation)
- **G-55** `timeFromYWithAdjacentSnap` (line 4280): if `!adjacentEventSnapEnabled` (AppStorage default true) → grid-snap only. Else compute `raw` time at `snapMinutes:1` (unrounded), `thresholdSeconds = adjacentEventSnapThresholdPt(8) / hourHeight * 3600`, then `calendarApplyAdjacentEventSnap(candidate, raw, neighborEdges, thresholdSeconds)` (TimelineEditMapping:309): pick the neighbor edge within threshold nearest to `raw` (test against raw, not rounded, to avoid the 15-min round pushing out of magnetic zone); return that edge + flag, else candidate + nil.
- **G-56** `neighborEventEdges` (line 4305) = every occurrence's `range.start` and `range.end` on this day. Snap haptic (`checkAdjacentSnapHaptic`, line 4421) fires the selection haptic on engage/disengage of either edge.

---

## 5. Absorption drop-targeting (todo → event)

- **G-57** Computed once per body re-eval per day (`dropTargetEventID`, TimelineView.swift:3658). Gated: `isDragActive`, NOT `isHorizontalAutoScrolling`/`isHorizontalEdgeDragging`, dragged is a non-recurring `.todo` (`cachedDraggedTodo`), `liveDraggedPreviewRange != nil`, `dragState.currentTouchPointGlobal` present and its X within the day's `dayFrameInGlobal`.
- **G-58** 2D spatial hit-test against each candidate's **rendered** frame (z-ordered by stack-peek depth): for each `occ` where `kind==.event`, `id != dragged.id`, `absorbedIntoEventID==nil`:
  - X rect from overlap slot: `xStart = dayContentMinX + eventAreaWidth*slot.xOffsetFraction`, `xEnd = + widthFraction*eventAreaWidth`. Embedded interrupts use parent slot + `calendarInterruptChildOverlayGeometry` with synthetic depth `parentSlot.depth+1` (line 3698–3707).
  - Y rect via `calendarTimelineYFraction(occ.range.start|end, leading/trailing extended)` × `contentHeight` + `dayFrameInGlobal.minY + headerHeight` (line 3728–3741) — uses the renderer's exact formula so the hit rect aligns even under drag-time boundary extension.
  - Require `touch.x ∈ [xStart,xEnd]` and `touch.y ∈ [yStart,yEnd]`; pick the candidate with greatest depth (topmost). Returns `bestTopmost?.id`.
- **G-59** Side-channel write (line 3765): a hidden `Color.clear.onChange(of: dropTargetEventID)`: write `dragState.currentDropTargetEventID = new` unconditionally when non-nil; clear only if `currentDropTargetEventID == old` (only-clear-if-we-still-own, to survive cross-day write races in week/3-day mode where multiple day views run this).
- **G-60** Drop commit (`handleEventDrag`, CalendarPageView:3508): on drag end of a non-recurring `.todo` with `|offset.x|>10 || |offset.y|>10`, parent = `currentDropTargetEventID` resolved (preferred) else time-overlap fallback (`range.start < newRange.end && newRange.start < range.end`). If parent found: commit the new time FIRST (`updateCalendarEvent`), THEN `absorbTodoIntoEvent(todoID, parentEventID)`.
- **G-61** Per-block highlight is a single UUID compare: `isAbsorptionDropTarget = (dropTargetEventID == event.id)` (TimelineView.swift:4943) — keeps Equatable cheap; non-targets skip re-render.
- **G-62** External-source drop path: `TodoEventAbsorptionDragDropModifier` (TimelineView.swift:3014) attaches `.onDrop(of:[.text])` only on `.event` blocks; loads a UUID string → `onAbsorb(todoID)`. Canvas-internal todo drag-to-absorb was removed (conflicted with the UIKit long-press); absorption from the canvas is now picker-driven.

---

## 6. Tap, long-press menu, focus entry

- **G-63** Tap: SwiftUI `.onTapGesture { onTap?() }` on the event block (EventBlock.swift:2911). Hit area honors the same fall-through inset via `.contentShape` (G-5). Consumer fires `onEventTap?(event, actionDate)` only when `!isPinchActive && onEventTap != nil` (TimelineView.swift:5020).
- **G-64** Floating-menu / express-menu staging (CalendarPageView): on `onLongPressBegan` → `handleTimelineLongPressBegan` (2796) → `scheduleFloatingMenuActivation` (2879): immediately sets `floatingMenuOccurrence`; if `floatingMenuActivationDelay (0.65s) > 0` schedules a cancellable `Task` that sleeps 0.65s then (token-guarded) sets `floatingMenuAnchor` (express menu appears at total ~1.0s hold). Edit mode (focus + handles) engages at the 0.35s manipulation threshold; menu only at 1.0s.
- **G-65** `onManipulationPromotion` → `handleTimelineManipulationPromotion` (2770): `resetFloatingMenuState()` (cancels pending menu since the user is dragging), clears interrupt composer, `setFocus(event, occurrenceID)`. So any drag past 8pt cancels the pending express menu and enters focus.
- **G-66** `onLongPressResolved` → `handleTimelineLongPressResolved` (2811): `cancelPendingFloatingMenuActivation()`. If `didMove`: `hideFloatingMenu()`, and if `.cancelled` clear focus. Else if `.completed` (held, no move): `beginResizeGrace(...)` + `floatingMenuInteractive = (anchor != nil)`. Else (`.cancelled`, no move): hide menu + clear focus.
- **G-67** `resetFloatingMenuState` is also fired on horizontal-scroll interaction begin (2870) and non-event tap (2859). Floating menu overlay `.allowsHitTesting(floatingMenuInteractive)` (CalendarPageView:1536) — non-interactive while still in hold-staging.

---

## 7. Pinch (timeline zoom) — `MagnificationGesture` + `PinchScrollCoordinator`

The actual zoom is a SwiftUI `MagnificationGesture` (`.simultaneousGesture`, TimelineView.swift:1528, 1583). `PinchScrollCoordinator` is a **UIKit observer only** that cancels in-progress scroll pans and blocks pinch during event manipulation.

### 7.1 PinchScrollCoordinator (TimelineView.swift:994)
- **G-68** `PinchScrollProbeView` is `isUserInteractionEnabled=false`, attaches in `didMoveToWindow` deferred one runloop (`DispatchQueue.main.async`) so the SwiftUI hierarchy is settled (line 1131–1139).
- **G-69** `attachIfNeeded` (line 1022): finds nearest ancestor `UIScrollView`; if found, adds a `UIPinchGestureRecognizer` (`cancelsTouchesInView=false`, delegate=self) onto it, and sets `scrollView.panGestureRecognizer.maximumNumberOfTouches = 1` (so a second finger mid-scroll cancels the pan and lets pinch take over). Idempotent while `attachedScrollView.window != nil`.
- **G-70** `handlePinch` (line 1049): on `.began`, if the scroll pan is `.began|.changed`, toggle `pan.isEnabled=false;true` to force-cancel the active scroll so pinch wins. The recognizer itself runs no zoom logic.
- **G-71** Delegate gates: `gestureRecognizerShouldBegin` returns `false` when `gestureRecognizer === pinchRecognizer && isInteractionBlocked()` (line 1065). `isInteractionBlocked = { dragState.draggingEventID != nil }` (line 1888) — **pinch is fully suppressed while any event is being dragged.** `shouldRecognizeSimultaneouslyWith` → true (coexist), `shouldRequireFailureOf` → false, `shouldBeRequiredToFailBy` → false (detect 2nd finger ASAP, line 1085–1101).
- **G-72** Graceful fallback: if no ancestor scroll view found, recognizer never attaches and behavior degrades to plain `.scrollDisabled(isRangePinchActive)` (line 1895) with no regression.

### 7.2 MagnificationGesture handlers (TimelineView.swift:1583–1739)
- **G-73** `.onChanged` first tick (`!isRangePinchActive`, line 1595): set `isRangePinchActive=true`; capture `rangePinchReferenceScale=safeScale (max 0.01,raw)`, `rangePinchInitialHourHeight=hourHeight`, reset boundary progress/step/latched; freeze `rangePinchFrozenSlotMinutes=slotMinutes` (stops legend flicker around the 76pt slot-density threshold); capture `pinchAnchorTimeHours = calendarPinchAnchorTimeHours(scrollY, viewportHeight, topOverlayInset, hourHeight)` (line 681): `(scrollY + viewportH/2 − topOverlayInset)/hourHeight`; seed temporal-stretch haptic state; prepare all haptics.
- **G-74** Per-change: `effectiveScale = safeScale / referenceScale`; `nextHourHeight = calendarTimelineHourHeightAfterPinchScale(initialHourHeight, effectiveScale, min:effectiveMinHourHeight, max:96)` = `clamp(initialHourHeight*scale, min, 96)` (line 576). `pinchMin = effectiveMinHourHeight` (the "whole day fits" fit-height, possibly snapping up on first tick after rotation, line 1633).
- **G-75** If `|next−prev| > 0.0001`: update temporal-stretch haptics; then in a single `withTransaction(disablesAnimations=true)` write `hourHeight=next` AND (if anchor set) `onPinchScrollAdjust?(calendarPinchAdjustedScrollY(anchorTime, viewportH, topInset, next))` = `topInset + anchorTime*next − viewportH/2` (line 695). **Both writes batched in one transaction** to avoid 1-frame anchor drift. Rewrite MUST keep hourHeight + scrollY co-committed.
- **G-76** Boundary resistance: `step = calendarPinchDirectionFromScale(effectiveScale, threshold:0.04)` (−1 zoom-in past max, +1 zoom-out past min, 0 neutral). Detect `pushingPastUpperBound`/`pushingPastLowerBound` (proposed beyond limit AND next clamped at limit). If pushing: `resistanceProgress = calendarPinchBoundaryResistanceProgress(scale, step, 0.04, 0.28)` (smoothstep on overshoot), `updateRangePinchBoundaryProgress(toward:)` (eased follow factor 0.35), and on first latch fire `rangePinchBoundaryHaptic(0.65)`. Visual feedback = `rangePinchVisualScaleY = calendarPinchBoundaryVisualScale(step, progress, maxVisualDelta:0.035)` applied as `.scaleEffect(y:)` (line 1527, 1575).
- **G-77** `.onEnded` (`handleRangePinchEnded`, line 1706): `isRangePinchActive=false`; reset reference scale, `rangePinchInitialHourHeight=hourHeight`, clear boundary latch/step, `pinchAnchorTimeHours=nil`; release frozen slot minutes in `withAnimation(.easeInOut(0.3))` (crossfades the `.id(effectiveSlotMinutes)` TimeAxisLabels identity flip); fire `onHourHeightCommit?()` → `commitTimelineHourHeight()`. If boundary progress > 0, spring it back to 0 (`.interactiveSpring(0.22, 0.78)`).
- **G-78** `isRangePinchActive` ALSO drives: `.scrollDisabled(isRangePinchActive)` (line 1895), `isPinchActive` passed to day views (line 2345) which collapses N EventBlocks into one Canvas and removes drag overlays (G-2), and gates tap/long-press (`onEventTap`/`onEventLongPressBegan` are nil when `isPinchActive`, line 5020–5021).

---

## 8. Coordinator-survives-rebuild concern (LazyHStack / render gating)

- **G-79** Day columns render through `calendarShouldRenderFullDayColumn` (TimelineView.swift:394): full within `±renderBuffer` of `renderCenter`, OR if the offset is the drag-source day (`dragSourceDayOffset`). Outside → `Color.clear` placeholder. This keeps the HStack **stable** (no LazyHStack recycling) so UIViewRepresentable gesture coordinators are not destroyed mid-drag.
- **G-80** Safety guard (line 401): the drag-source day is NEVER replaced by a placeholder (`calendarDragSourceDayOffset` from `draggingOriginalRange`, line 409) — the active gesture coordinator must stay alive through cross-day drag.
- **G-81** `updateUIView` does NOT nil `onDragEnded` while a drag is in progress (`if onDragEnded != nil || !isDragInProgress`, EventBlock.swift:1212) — after a boundary page the source block may be re-evaluated with `isInteractionAllowed=false`, but the end callback must still fire to commit. `onDragEnded` itself is gated `(isInteractionAllowed || isDraggedEvent) && !isGraceResizeTarget` (TimelineView.swift:5060).
- **State the coordinator holds that MUST survive a rebuild** (all on `Coordinator`, EventBlock.swift:1261–1287): `parent` (closures), `initialPointInWindow`, `lastLocationInWindow`, `autoScrollCompensation{X,Y}`, `horizontalScrollView`/`verticalScrollView` weak refs, `activeGesture` weak ref, `autoScrollVelocity{X,Y}`, `autoScrollDisplayLink`, `isHorizontalSnapSuppressed`, `disabledScrollGestures`/`savedCanCancelContentTouches`, `hasMovedAfterLongPress`, `hasPromotedManipulation`, `currentMode`, `lastSnappedStep`, boundary-page counters/origin/timestamp. In the rewrite, the analogous controller object must be owned by something with lifetime independent of per-frame view recycling (the gesture state, the captured scroll-view refs, the accumulated compensation, and the decided drag mode cannot be re-derived after a rebuild).

---

## 9. Coordinate transforms used (must match exactly)

- **G-82** All drag deltas computed in **window** coordinates: `gesture.location(in: nil)` minus `initialPointInWindow` (EventBlock.swift:1327, 1382, 1575). Block frame for callbacks: `view.convert(view.bounds, to: nil)` (line 1291).
- **G-83** Auto-scroll viewport position: `lastLocationInWindow − scrollView.convert(scrollView.bounds, to:nil).min{X|Y}` (EventBlock.swift:1864; CreationDragGesture line 2954).
- **G-84** Absorption hit-test: touch is `dragState.currentTouchPointGlobal` (window coords from the UIKit handler) tested against day frame `dayFrameInGlobal` and per-event rendered rects in global coords (TimelineView.swift:3665–3742).
- **G-85** Resize-mode decision uses **view-local** coords: `gesture.location(in: view)` (EventBlock.swift:1322) for `calendarResolveDragMode`.

---

## 10. Parity checklist summary

Total interaction parity items: **85** (G-1 … G-85).

Coverage by interaction:
- Move/resize drag (recognizer, hit area, began/changed/ended, offset math, terminal recovery, scroll suppression): G-1 … G-34.
- Edge auto-scroll (event): G-35 … G-41.
- Single-day boundary paging: G-42 … G-45.
- Drag-to-create: G-46 … G-56.
- Absorption drop-targeting: G-57 … G-62.
- Tap / long-press menu / focus entry: G-63 … G-67.
- Pinch (coordinator + magnification): G-68 … G-78.
- Coordinator-survives-rebuild: G-79 … G-81.
- Coordinate transforms: G-82 … G-85.
