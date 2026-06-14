# 03 — Layout & Geometry Parity Baseline

Exact current-behavior spec for the SwiftUI calendar timeline's **layout & geometry math**, captured so a UIKit + CALayer rewrite reproduces it 1:1. A sub-pixel difference is a visible drift. Every formula and magic number below is load-bearing.

Primary files:
- `Done/Views/Calendar/Components/Timeline/TimelineEditMapping.swift` (the canonical time↔Y mapping functions + base constants)
- `Done/Views/Calendar/CalendarLayout.swift` (yOffset, occurrence filtering, overlap topology)
- `Done/Views/Calendar/Components/Timeline/TimelineView.swift` (the rendering views, insets, grid, now-line, pinch, day pager)
- `Done/Views/Calendar/CalendarViewState.swift` (hourHeight persistence + clamps)
- `Done/Views/Calendar/Components/Timeline/Event/EventBlock.swift` (interrupt/compound notch geometry)
- `Done/Views/Calendar/CalendarPageView.swift` (scroll offset, topOverlayInset, range-mode → day count)

---

## 0. Constant Tables (capture every number)

### 0.1 Base time-window constants
| Constant | Value | File:line | Meaning |
|---|---|---|---|
| `calendarTimelineBaseVisibleHours` | `24` | TimelineEditMapping.swift:10 | Hours in a base (un-extended) day column. |
| `calendarTimelineMaximumBoundaryExtensionHours` | `12` | TimelineEditMapping.swift:11 | Max hours the leading/trailing window can grow during edit. |

### 0.2 hourHeight (the master scale; "points per hour")
| Constant | Value | File:line | Meaning |
|---|---|---|---|
| `calendarTimelineHourHeightDefault` | `56` | CalendarViewState.swift:11 | Initial / persisted-fallback hour height. |
| `calendarTimelineHourHeightMin` | `12` | CalendarViewState.swift:17 | Absolute safety floor (live pinch min is usually larger; see §6.2). |
| `calendarTimelineHourHeightMax` | `96` | CalendarViewState.swift:18 | Hard ceiling. |
| `CalendarHourHeightBox(_:=56)` default | `56` | TimelineEditMapping.swift:30 | Default seed of the live reference-type holder. |
| Persistence key | `"calendar.timeline.hourHeight"` | CalendarViewState.swift:33 | `UserDefaults` Double; committed on pinch end. |
| Clamp | `min(max(value, 12), 96)` | CalendarViewState.swift:76-78 | Applied on every set; set ignored if `abs(Δ) ≤ 0.0001` (line 68). |

`CalendarHourHeightBox` is a `@MainActor final class` holding `var value: CGFloat`. It is a **non-observable** mirror of `calendarState.timelineHourHeight`, threaded into `EventBlock` for drag/resize math so hourHeight reads don't invalidate the View struct. CalendarPageView mirrors every write via `.onChange` + seeds on `.onAppear` (TimelineEditMapping.swift:13-33).

### 0.3 Insets, widths, paddings (TimelineDayView, TimelineView.swift)
| Name | Formula / value | File:line | Meaning |
|---|---|---|---|
| `labelWidth` | `26` | 1203 | Left time-axis gutter width. |
| `daySpacing` | `0` | 1204 | Gap between day columns. |
| `eventHorizontalInset` | `isSingleDay ? 8 : 4` | 1205 | L/R inset of the event area inside a day column. |
| `scrollHorizontalPadding` | `0` | 1206 | |
| `timelineEdgePadding` | `2` | 1207 | Outer padding subtracted twice from proxy width. |
| `headerHeight` | `calendarTimelineTopInset(hourHeight)` | 1208 | See §1.1. The "header" is empty headroom above 00:00. |
| `allDayPillHeight` | `28` | 1211 | Height per all-day row. |
| `allDaySectionPadding` | `4` | 1212 | Top+bottom padding of the all-day band. |
| `timelineBottomInset` | `calendarTimelineBottomInset(hourHeight)` | 1216 | See §1.1. |
| `stackPeekStripWidthPt` | `8` | 3189 | Stack-peek strip / interrupt child leading inset (shared constant). |
| `stackPeekPeerToleranceSeconds` | `20*60` (1200 s) | 3201 | Peer tolerance for stack-peek (see §4). |
| Pinch boundary threshold | `0.04` | 1567 | `rangePinchBoundaryThreshold`. |
| Pinch saturation overshoot | `0.28` | 1568 | `rangePinchSaturationOvershoot`. |
| `temporalStretchStepSize` | `4` | 2454 | Haptic-step granularity in points; step idx = `floor(h/4)` (2456-2459). |
| `temporalStretchBoundaryEpsilon` | `0.001` | 2453 | Bound-hit epsilon. |

### 0.4 Width derivation (body GeometryReader, TimelineView.swift:1510-1517)
```
availableWidth   = max(0, proxy.size.width - labelWidth - timelineEdgePadding*2)   // - 26 - 4
contentWidth     = max(0, availableWidth - scrollHorizontalPadding*2)              // == availableWidth (padding 0)
dayWidth         = isSingleDay ? contentWidth
                               : max(0, (contentWidth - daySpacing*(daysCount-1)) / daysCount)
dayFrameWidth    = isSingleDay ? availableWidth : dayWidth
effectiveSpacing = isSingleDay ? 0 : daySpacing                                    // always 0 today
eventAreaWidth   = contentWidth - eventHorizontalInset*2     // per day column (3797, 4043, 4630)
```
Note `contentWidth` passed to each day column is that column's `dayWidth`.

---

## 1. Vertical Placement (time → Y)

### 1.1 Header / inset derivation (TimelineView.swift:501-508)
```
calendarTimelineTopInset(hourHeight)    = max(14, round(hourHeight * 0.28))     // == headerHeight
calendarTimelineBottomInset(hourHeight) = max(8,  round(hourHeight * 0.15))     // == timelineBottomInset
```
- `headerHeight` is the empty headroom above 00:00; **Y of midnight = headerHeight**.
- Both use `round(...)` → integer-ish points; reproduce the rounding exactly.
- For small hourHeight (≤ ~50) `headerHeight` clamps to 14 and bottomInset to 8 → constant 22 px chrome (the `timelineChromeBudget` in §6.1).

### 1.2 The canonical fraction-based mapping (TimelineEditMapping.swift)
The current renderer (TimelineDayView) positions events as **fraction of content height**, NOT via a raw per-hour multiply. Both forms are algebraically identical; reproduce the fraction form for parity at boundary-extension edges.

```
visibleStart(anchor, leadingExt)  = startOfDay(anchor) - leadingExt*3600 s         (88-95)
visibleEnd(anchor, trailingExt)   = startOfDay(anchor) + (24 + trailingExt)*3600 s (97-106)
totalVisibleHours(L,T)            = 24 + max(0,L) + max(0,T)                        (81-86)
contentHeight(h,L,T)              = totalVisibleHours(L,T) * h                      (112-122)

yFraction(date)  = clamp( (date - visibleStart) / (totalVisibleHours*3600), 0, 1 ) (126-146)
durationFraction(seconds, L,T) = max(0,seconds) / (totalVisibleHours*3600)         (151-163)  // NOT clamped ≤1
```

### 1.3 Event block Y & height (TimelineDayView, the live ForEach path)
TimelineView.swift:3903-3957. For each occurrence:
```
blockSeconds      = isDragged ? (renderedRange.end - renderedRange.start)
                              : (min(end,visibleEnd) - max(start,visibleStart))     // clipped, ≥0
blockHeightFrac   = durationFraction(blockSeconds, L, T)
_blockHeight      = max(0, blockHeightFrac * contentHeight - 3)                     // -3 fudge (3918)
blockYFraction    = yFraction(renderedRange.start, ...)
blockY            = headerHeight + blockYFraction * contentHeight                   (3925)
final .offset.y   = blockY + 1.5                                                    (3957)
```
**The +1.5 / -3 fudge** (also at 4509, 4543-4544, 4677-4683):
- `+1.5` shifts the block top down by 1.5 pt.
- `-3` shrinks the height by 3 pt.
- Net effect: a 1.5 pt visual gap above AND below each block (block sits inside its time slot with 1.5 pt breathing room top and bottom), so adjacent back-to-back events don't touch. **These are pure cosmetic gaps — reproduce both exactly.** (Same pair appears in the pinch Canvas, §3, and the focused-block path.)

Block X / width (TimelineView.swift:3833-3850):
```
overlapGap = parentHasOverlap ? 2 : 0                            // 2 px gutter between overlapping cols (3834)
blockWidth = eventAreaWidth * slot.widthFraction - overlapGap
blockX     = eventHorizontalInset + eventAreaWidth * slot.xOffsetFraction
```
(Interrupt-child variants offset blockX/width via the overlay geometry — §5.)

### 1.4 Legacy raw-multiply forms (still present; identical math)
- `CalendarLayout.yOffset` (CalendarLayout.swift:245-256): `headerHeight + (max(start,dayStart)-dayStart)/3600 * hourHeight`.
- `CalendarLayout.eventHeight` (258-273): clips end to `dayStart + 24h`, `max(minimumHeight, sec/3600 * hourHeight)`. **No -3 here** — minimum-height clamp instead.
- `calendarTimelineYPosition` (196-218): `headerHeight + (date-visibleStart)/3600 * hourHeight`, clamped to `[headerHeight, headerHeight + totalVisibleHours*hourHeight]`. Used by axis markers.

### 1.5 Y → time (inverse; for drag/tap)
- `calendarTimelineDateFromYPosition` (TimelineEditMapping.swift:220-274): `minutes = (y-headerHeight)/hourHeight*60`; snap `round(min / snap)*snap` (default snap 15); resolved date clamped to `[allowedStart, allowedEnd]` where allowed bounds use the **max** extension (12h) on each side.
- `CalendarLayout.timeFromYOffset` (850-868): same, clamps minutes to `[0, 24*60]`.
- Grid snap: 15 min round-to-nearest is the app's core discretization. `calendarSnapDateToMinuteGrid` (292-297) rounds `timeIntervalSinceReferenceDate` to a 15-min grid.

### 1.6 contentHeight, slotHeight, timelineHeight, totalHeight
TimelineView.swift:
```
contentHeight   = calendarTimelineContentHeight(h, L, T)                 (4749-4755)
slotMinutes     = calendarLegendSlotMinutes(h)  // 30 if h≥76 else 60    (536-541, 1217)
effectiveSlotMinutes = rangePinchFrozenSlotMinutes ?? slotMinutes        (1221)  // frozen during pinch
slotHeight      = h * effectiveSlotMinutes / 60                          (1222)
slotCount       = max(1, Int( totalVisibleHours*60 / effectiveSlotMinutes ) + 1)  (1294-1306)
timelineHeight  = headerHeight + slotCount*slotHeight + timelineBottomInset        (1307)
allDayHeight    = maxAllDayCount>0 ? maxAllDayCount*28 + 4*2 : 0          (1320-1324)
totalHeight     = allDayHeight + timelineHeight                          (1325)
```
Canvas frames: events canvas height = `headerHeight + contentHeight + timelineBottomInset` (4740). Grid total height = `headerHeight + slotCount*slotHeight + timelineBottomInset` (4859). (Note: `slotCount*slotHeight == totalVisibleHours*hourHeight == contentHeight` up to the `+1` extra slot / integer rounding — the grid draws one extra trailing line.)

---

## 2. Now-line

### 2.1 SwiftUI path (outside pinch) — TimelineView.swift:4578-4599 + 4757-4764
```
shouldShow = calendar.isDate(day, inSameDayAs: now)                      (511-517)
y          = headerHeight + yFraction(now, containing:date, L,T) * contentHeight   (nowIndicatorYOffset, 4757)
lineHeight = 1.5 ; dotSize = 7
line: Rectangle fill color.opacity(0.92), width = contentWidth - eventHorizontalInset*2,
      .offset(x: eventHorizontalInset, y: y - lineHeight/2)
dot:  Circle  fill color, dotSize 7, .offset(x: eventHorizontalInset - dotSize/2, y: y - dotSize/2)
shadow: black 0.18, radius 1.5, x:0, y:0.5
refresh: SwiftUI.TimelineView(.periodic(by: 1)) → advances every 1 s
zIndex 100
```

### 2.2 Pinch path (inside pinch) — TimelineView.swift:4634-4658
Drawn **inside the same Canvas as events** to share the rendering pass (no `.offset` sub-pixel jitter). Identical math: `nowY = headerHeight + yFraction(now)*contentHeight`, line rect `(x:eventHorizontalInset, y:nowY-0.75, w:eventAreaWidth, h:1.5)`, dot ellipse `(x:eventHorizontalInset-3.5, y:nowY-3.5, 7×7)`, line opacity 0.92.

### 2.3 Clamped legacy form & THE JITTER LESSON
- `calendarNowIndicatorYOffset` (520-533): `y = headerHeight + secondsSinceStart/3600 * hourHeight`, clamped `[headerHeight, headerHeight + 24*hourHeight]`. `now` first clamped to `[dayStart, dayEnd]`.
- **Jitter lesson (TimelineView.swift:4059-4069):** SwiftUI `.offset(y:)` renders the 1.5 pt line at fractional sub-pixels → visible jitter as hourHeight changes per pinch frame. Fix = during pinch, draw the line in the events `Canvas` with identical fraction math; outside pinch the `.offset` SwiftUI path resumes (so the 1 s periodic refresh advances it). **CALayer rewrite: pixel-align the now-line Y (round to device-pixel grid) or it will shimmer during pinch/scroll.**
- Legend label hiding on collision: `calendarShouldHideLegendHourLabel` (544-555) hides the hour label when `abs(nowY - legendY) ≤ 10` pt.

---

## 3. Pinch-active Events Canvas (parity twin of the ForEach path)

TimelineView.swift:4626-4744. Single `Canvas(opaque:false, colorMode:.nonLinear, rendersAsynchronously:false)`. Fraction math mirrors §1.3 exactly so geometry matches at pinch boundaries:
```
blockWidth     = max(0, eventAreaWidth*slot.widthFraction - overlapGap)   // overlapGap = widthFraction<1 ? 2 : 0
blockX         = eventHorizontalInset + eventAreaWidth*slot.xOffsetFraction
blockHeight    = max(0, durationFraction(clippedSeconds)*contentHeight - 3)
blockY         = headerHeight + yFraction(start)*contentHeight + 1.5
cornerRadius   = isInterrupt ? 5 : 10
fill           = color.opacity(0.18) ; stroke = color.opacity(0.55), lineWidth 0.5
text rect      = (minX+4, minY+2, w-8, h-4)  font system 11 semibold, color = event color
text alpha ramp: h≥22 →1 ; h≤14 →0 ; else (h-14)/8
```
**Text fade ramp** (4701-4705) is reused in both paths — reproduce the 14/22/8 numbers.

---

## 4. Overlap Topology (MOST COMPLEX — `CalendarLayout`)

All in `CalendarLayout.swift:331-848`. Two modes selected by `peekFraction`:
- `peekFraction == 0` → **equal-split columns** (legacy).
- `peekFraction > 0`  → **stack-with-peek**. Live value (TimelineView.swift:3206-3210): `stackPeekFraction = stripWidth(8) / (contentWidth - eventHorizontalInset*2)`, zero if area ≤ 16. So peek is ~`8 / eventAreaWidth` fraction.

`EventOverlapSlot` (339-361): `{ xOffsetFraction [0,1), widthFraction (0,1], zIndex Double, depth Int, coverRanges [TimeRange] }`. Default = `(0, 1, z=1, depth 0, [])`.

### Step 0 — entry (`overlapLayout`, 416-469)
- ≤1 occurrence → all get `.default`.
- Else: find clusters (Step 1), then layout each cluster (Steps 2-7) with `xStart=0, width=1, baseZ=1`.

### Step 1 — Cluster via Union-Find (`findOverlapClusters`, 472-521)
- Pairwise overlap on **clipped** intervals: `si=max(start_i,visibleStart)`, `ei=min(end_i,visibleEnd)`; union i,j iff `si < ej && sj < ei` (strict). **ALL kinds union** (event/todo/interrupt) — an earlier todo-skip attempt broke layout and was reverted (496-502). Group by union-find root.

### Step 2 — within `layoutCluster` (527-797): build packing groups
1. `embeddedInterruptParentIDs` = parent IDs of embedded-state interrupt children in the cluster (543-551).
2. **Sort** the cluster (554-583): by clipped start asc; tiebreak by interrupt packing-group key (820-833) so parent+children stay adjacent; then by interrupt rank (interrupt=1, else 0, 841-848); then by clipped duration **desc** (longer first); then `id`.
3. Group members by `calendarInterruptPackingGroupKey`:
   - embedded interrupt child → `"interrupt-family:<parentID>"`
   - parent of an embedded child → `"interrupt-family:<anchorID>"` (anchor = `recurrenceParentId ?? id`)
   - else → `"occurrence:<occ.id>"` (its own singleton group).
4. Each `OverlapPackingGroup` spans `start = min` clipped start, `end = max` clipped end over members; sorted start-asc, end-**desc** tiebreak, then firstSeenIndex (604-624).
5. If exactly 1 group → all members full width `(xStart, width, baseZ)` (626-637).

### Step 3 — Greedy column packing (639-687)
Process groups in start-asc order. For each group, place in the **first** existing column whose members don't time-overlap it; else new column.
- "Blocked" test (668-674): `group.start < other.end && other.start < group.end`. **Exception in stack-peek:** if `peekFraction>0` AND `peerTimeMatch(group,other)` → NOT blocked (peers may share a column).
- `peerTimeMatch(a,b)` (659-663): `abs(a.start-b.start) ≤ peerTolerance && abs(a.end-b.end) ≤ peerTolerance`. NOT transitive.
- `totalCols = columns.count`.

### Step 4a — STACK-PEEK mode (`peekFraction > 0`, 691-762)
`depth = column index`. For each group: peers = members of its column matching `peerTimeMatch`, sorted by id; `peerCount = max(1, peerGroups.count)`, `peerIndex = position in peers`. Each member → entry `{depth, peerCount, peerIndex}`. Then per entry:
```
depthXStart = xStart + depth*peekFraction
depthWidth  = max(0, width - depth*peekFraction)
myWidth     = depthWidth / peerCount
myXOffset   = depthXStart + peerIndex*myWidth
z           = baseZ + depth*0.01
coverRanges = mergeTimeRanges( for each entry with depth>mine: clip overlap [max(myStart,oStart), min(myEnd,oEnd)] )   // peers (same depth) never cover
```
Deeper depth = drawn on top (z grows by 0.01/depth); later-starting events get higher depth (render on top). `coverRanges` feed text-fitting so titles avoid the obscured strip.

### Step 4b — EQUAL-SPLIT mode (`peekFraction == 0`, 764-796)
1. Expand each group rightward into adjacent free columns: for `nextCol` in `col+1..<totalCols`, stop at first column containing a time-overlapping group; `groupSpanEnd[group] = lastFreeCol`.
2. `colWidth = width / totalCols`. For each group: `col`, `end=spanEnd`, `span = end-col+1`; `x = xStart + colWidth*col`, `w = colWidth*span`, `zIndex = baseZ`. All members share that slot.

### `mergeTimeRanges` (802-818)
Sort by start (end tiebreak); merge when `range.start ≤ last.end`, extending `last.end = max(...)`.

**Confidence: HIGH / fully documented.** Both modes, the union-find, the interrupt grouping/sort tiebreak chain, peer tolerance, depth/z/width/xOffset formulas, and cover-range derivation are all captured with exact line refs. The only behavior that depends on *external* state (not in this file) is `stackPeekFraction`'s live value (TimelineView.swift:3206) and the absorption stack-peek strip width — both documented in §0.3/§4 intro.

---

## 5. Compound Interrupt / Notch Geometry (EventBlock.swift)

### 5.1 Child overlay (the interrupt block sitting inside a parent) — 269-281
```
leadingInset = 8
width   = max(0, parentWidth - 8)
xOffset = min(8, parentWidth)
```
`calendarInterruptChildOverlayGeometry` is an alias of the above. In TimelineView, child blockX = `parentX + overlay.xOffset`, width = `overlay.width - overlapGap` (3822-3850, 4046-4050). parentX/parentWidth derive from the parent's slot fractions × eventAreaWidth.

### 5.2 Cutout (notch the parent carves for an embedded child) — 283-293
```
childOverlay = childOverlayGeometry(parentWidth)        // xOffset 8
xOffset = max(0, childOverlay.xOffset - moatWidth)      // moatWidth = horizontalGap
width   = max(0, parentWidth - xOffset)
```

### 5.3 Compound parent geometry (`calendarInterruptParentCompoundGeometry`, 355-516)
Inputs: `parentRange, childRanges, parentWidth, parentHeight, horizontalGap, verticalGap`.
```
totalDuration = max(parentEnd - parentStart, 1)
cutoutGeometry = cutoutGeometry(parentWidth, moatWidth: horizontalGap)
For each merged child range:
  topProgress     = (range.start - parentStart)/totalDuration
  segmentProgress = (range.end   - range.start)/totalDuration
  rawTop = parentHeight*topProgress - verticalGap ; top = max(0, rawTop)
  rawHeight = parentHeight*segmentProgress + verticalGap*2
  height = min( max(verticalGap*2 + 2, rawHeight), max(0, parentHeight - top) )
  rect = (x: cutout.xOffset, y: top, w: cutout.width, h: height)
```
- rects sorted by minY (maxY tiebreak); then **merged** when `rect.minY ≤ last.maxY` (extend last; 405-421).
- `hasTopLobe = rect.minY > 0.5` ; `hasBottomLobe = rect.maxY < parentHeight - 0.5` (426-427). The 0.5 epsilons suppress lobes at the exact top/bottom edge.
- `spineRect = (0,0, max(0,cutout.xOffset), parentHeight)` (507-512) — the always-visible left spine = the 8 pt strip.
- `visibleSegments`: walk cutouts top→bottom; gap before a cutout → full-width segment; the cutout band itself → spine-width (`max(0,cutout.xOffset)`) segment; trailing gap → full-width. Empty → one full-height full-width segment. Then **normalize**: merge consecutive segments where `abs(Δwidth)<0.5 && abs(gap)<0.5` (478-494). `contentRects` = segments as rects with `x=0`.
- `isStandaloneSpine` = exactly 1 cutout with no top & no bottom lobe.

### 5.4 Stack-peek text geometry augmentation (528+)
Projects cover ranges to parent Y, intersects with each segment, shrinks intersections to `peekStripWidth` (8) so text avoids the covered strip. Silhouette (cutouts/spine) unchanged — only `contentRects` reflect covers.

---

## 6. Boundary Extension (leading / trailing extended hours)

### 6.1 Trigger (`calendarTimelineBoundaryExtensionHours`, TimelineEditMapping.swift:165-194)
```
dayStart = startOfDay(anchor) ; baseVisibleEnd = dayStart + 24h ; clampedMax = 12
anticipation = (source ∈ {moveDrag,resizeTop,resizeBottom}) ? 2*3600 : 0   // open 2 h early during active edit
leading  = (range.start < dayStart + anticipation)      ? 12 : 0
trailing = (range.end   > baseVisibleEnd - anticipation) ? 12 : 0
```
Each side is **all-or-nothing 12 h** (not gradual). `max(0,L)`/`max(0,T)` guards everywhere.

### 6.2 Cross-day "stuck at top" override (TimelineView.swift:1260-1266)
If dragging up (`source ∈ {moveDrag,resizeTop}`), `result.leading==0`, `verticalScrollY < hourHeight*2`, and `dragOffset.y < -hourHeight` → force `leading = 12`. (Lets a 23:00 event reach midnight when finger drag alone can't.)

### 6.3 Effects on content height & scroll
- contentHeight grows: `(24 + L + T) * hourHeight` (§1.2).
- Visible window: `[startOfDay - L·3600, startOfDay + (24+T)·3600]`.
- Adjacent-day occurrences are pulled in: `timelineVisibleOccurrences` (CalendarLayout.swift:185-242) adds offset-1 (leading) / offset+1 (trailing) day candidates, filters to `range.end>visibleStart && range.start<visibleEnd`, merges duplicate IDs by min-start/max-end, sorts start→end→id.
- **Scroll compensation on leading growth** (CalendarPageView.swift:637-674): when leadingHours increases by Δ, `targetOffsetY = max(0, currentOffsetY + Δ*hourHeight)` so the existing content stays put under the finger; applied only if `abs(Δoffset) > 0.5`.
- Vertical drag bounds clamp (TimelineView.swift:4965-4983): event move/resize is bounded to the theoretical ±12 h extension edges expressed as Y offsets (`minOffsetSeconds/3600*hourHeight … maxOffsetSeconds/3600*hourHeight`).

### 6.4 Boundary day hints (`calendarBoundaryDayHintPlacements`, 2718-2752)
- leading hint originY = `headerHeight + hintInset(8)`.
- trailing hint originY = `headerHeight + (L + 24)*hourHeight + hintInset(8)`.

### 6.5 Time-axis labels in extended region (TimelineDayView axis, 2627)
`totalMinutes = -leadingExtendedHours*60 + index*slotMinutes` → negative-hour labels in the leading zone.

---

## 7. Pinch Geometry

### 7.1 hourHeight from scale (TimelineView.swift:576-588)
```
proposed = initialHourHeight * scale
result   = clamp(proposed, minHourHeight, maxHourHeight)     // min = effectiveMin (§7.4), max = 96
```
Live (handleRangePinchChanged, 1625-1664): `effectiveScale = safeScale / referenceScale`; `nextHourHeight = afterPinchScale(rangePinchInitialHourHeight, effectiveScale, min: effectiveMin)`. Applied only if `abs(Δ) > 0.0001`, inside a `Transaction{ disablesAnimations = true }` that batches hourHeight **and** scroll Y in one render pass (1650-1663) — **critical**: separate writes cause a 1-frame anchor drift / jitter.

### 7.2 Anchor-time centering (581-703)
```
anchorTimeHours = (scrollY + viewportHeight/2 - topOverlayInset) / hourHeight   // capture at gesture start
// after scale:
adjustedScrollY = topOverlayInset + anchorTimeHours*hourHeight_new - viewportHeight/2
```
Keeps the time at viewport center fixed across the zoom. `topOverlayInset` matches `currentTimeScrollOffset`'s `scrollY = topOverlayInset + hours*hourHeight` convention (§8.1).

### 7.3 Pinch fit (largest "whole day fits") (630-645)
```
timelineChromeBudget = 22
availableForHours = viewportHeight - contentTopInset - contentBottomInset - allDayHeight - 22
fitHourHeight     = (availableForHours / 24) * 1.02        // 1.02 → content slightly taller than viewport so autoscroll has room
```
Layout it models: `topOverlayInset + allDayHeight + headerHeight + 24*hourHeight + bottomInset`.

### 7.4 Effective min during live pinch (658-672)
```
effectiveMin = max(safetyFloor(=12), fitHourHeight)
```
i.e. you can compress down to "whole day fits the unobscured viewport" but no further (then resistance, §7.5). Mode-aware via `contentTopInset` (includes the 34 pt day-legend bar in 3-day/week).

### 7.5 Boundary visual resistance (591-716)
```
resistanceProgress(scale, step, threshold=0.12, saturation=0.28):    // NOTE default threshold 0.12 here;
  overshoot = step<0 ? (scale-1)-threshold : (1-scale)-threshold     // live call passes threshold=0.04 (1692)
  if overshoot ≤ 0 → 0
  normalized = min(1, overshoot/saturation)
  return smoothstep: normalized²*(3-2*normalized)

direction(scale, threshold=0.04): scale ≥ 1+thr → -1 (zoom in) ; scale ≤ 1-thr → +1 ; else 0   (559-573)

visualScale(step, progress, maxDelta=0.05):
  eased = sin(progress*π/2) ; delta = 0.05*eased
  return step<0 ? 1+delta : 1-delta                                  (706-716)
```
Push-past detection (1670-1683): only engages resistance when `proposedHourHeight` exceeds the clamp AND `nextHourHeight` is pinned at the bound (within 0.0001). Haptic latches once per crossing (intensity 0.65).

### 7.6 Slot-density freeze during pinch
`effectiveSlotMinutes = rangePinchFrozenSlotMinutes ?? slotMinutes` (1221) so the grid/legend don't flicker as hourHeight crosses the 76 pt threshold (slot 30↔60). On pinch end, released inside `withAnimation(.easeInOut(0.3))` (1721-1723) → crossfade.

---

## 8. Day Pager (column count, width, liveness)

### 8.1 Range mode → day offsets (CalendarPageView.swift:170-178)
| Mode | offsets | daysCount |
|---|---|---|
| `.day` | `[0]` | 1 |
| `.threeDay` | `[-1,0,1]` | 3 |
| `.week` | `[-3,-2,-1,0,1,2,3]` | 7 |
| `.month` | grid (separate path) | — |

`currentTimeScrollOffset` (2666-2676): `rawOffset = topOverlayInset + (secondsSinceMidnight/3600)*hourHeight`; nudged up by `viewportHeight*0.3` so now lands ~30% from top; `max(0, raw - nudge)`.

`topOverlayInset` (618-635): `safeAreaTop + legendBandHeight(34) + capsuleVisibleHeight(0 or 52) + overlayGap(6)`.

### 8.2 Column geometry
Day-pager (CalendarPageView.swift:2265-2269): `dayWidth = daysCount==1 ? dayAreaWidth : max(0, dayAreaWidth/daysCount)`. Inside TimelineDayView, see §0.4. `dayColumnStep` (the horizontal drag→day step) = column width incl. spacing; `calendarDayOffsetFromHorizontalDrag` = `Int((offsetX/dayColumnStep).rounded())` (386-392).

### 8.3 Centered-vs-leading mapping (TimelineView.swift:326-377)
```
centerSlotIndex(daysCount) = max(0, daysCount/2)                      // day→0, 3day→1, week→3
centeredDayOffsetRange: [dayRange.lower + centerIndex, dayRange.upper - trailingCount]
leadingFromCentered = clamp(centered - centerIndex, leadingRange)
centeredFromLeading = clamp(leading + centerIndex, centeredRange)
continuousCenteredOffset = clamp( (leadingRange.lower + contentOffsetX/step) + centerIndex, centeredRange )
```

### 8.4 Liveness / render gating (394-468)
```
renderBuffer(daysCount) = max(daysCount/2 + 4, 7)
shouldRenderFullDayColumn(offset): |offset - renderCenter| ≤ renderBuffer  (else Color.clear placeholder)
  EXCEPT: drag-source day is always kept alive (gesture coordinator must survive).
isDayInVisibleViewport(offset): |offset - selectedDayOffset| ≤ (daysCount-1)/2
```
`DayColumnGate` (426-443): an `Equatable` view that blocks body re-eval while scrolling (returns `true` only when both sides are scrolling AND offset/shouldRender match). A `LazyHStack` is intentionally avoided — recycling would kill gesture coordinators; instead the HStack stays stable and off-buffer columns become `Color.clear`.

### 8.5 Default day range
`CalendarLayout.defaultDayRange = -30...30` (CalendarLayout.swift:17).

---

## 9. Grid (hour / half-hour lines)

TimelineView.swift:4855-4890.
```
lineWidth   = max(0, contentWidth - eventHorizontalInset*2)
lineInsetX  = (contentWidth - lineWidth)/2     // == eventHorizontalInset
isHalfHourGrid = (slotMinutes == 30)           // i.e. hourHeight ≥ 76
totalHeight = headerHeight + slotCount*slotHeight + timelineBottomInset
for index in 0..<slotCount:
  y = headerHeight + index*slotHeight
  isSubHourLine = isHalfHourGrid && index%2 != 0      // odd indices = half-hour lines
  if isDashed || isSubHourLine:
     stroke lineWidth = isSubHourLine ? 1.5 : 1 ; dash = isDashed ? [4,3] : [3,4]
  else:
     fill rect (x:lineInsetX, y, w:lineWidth, h:1)     // solid 1px hour line
```
- **Solid vs dashed:** hour lines are solid 1 px fills unless `style.gridDashed`. Half-hour lines (`isSubHourLine`) are always dashed (`[3,4]`, 1.5 pt) even when the style isn't dashed.
- `slotMinutes` here uses the LIVE value (not frozen) at line 4857 — the grid View; but `slotHeight`/`slotCount` use `effectiveSlotMinutes` (frozen). Reproduce this asymmetry.
- Grid color default `Color.secondary.opacity(0.15)`; `gridDashed` default `false` (916-922).

---

## 10. Sub-pixel / Pixel-alignment Checklist (parity-critical)

- [ ] `headerHeight`/`bottomInset` use `round(...)` — reproduce the rounding (§1.1).
- [ ] Now-line Y must be device-pixel-aligned to avoid shimmer; SwiftUI drew it via `.offset` outside pinch and via Canvas during pinch precisely because of jitter (§2.3).
- [ ] hourHeight + scroll Y must update in ONE pass during pinch (Transaction) or a 1-frame anchor drift appears (§7.1).
- [ ] +1.5 block top offset and -3 block height shrink are cosmetic gaps; apply both, everywhere (live path 3918/3957, pinch 4677/4683, focused 4543-4544/4509) (§1.3).
- [ ] overlapGap 2 px gutter between columns whenever `widthFraction < 1` (§1.3, §3).
- [ ] zIndex steps by 0.01 per depth in stack-peek (§4) — preserve ordering even though sub-0.01 z differences are invisible.
- [ ] Lobe-suppression epsilons 0.5 in compound geometry (§5.3); segment-merge epsilons 0.5.
- [ ] Strict vs non-strict overlap: cluster union uses strict `<` (§4 Step 1); column-blocked test uses strict `<` (§4 Step 3); leading/trailing crossing uses strict `<`/`>` (§6.1).
- [ ] Fraction form vs raw-multiply form are algebraically equal at L=T=0 but DIVERGE at boundary extension because the denominator becomes `(24+L+T)`. Use the fraction form (§1.2) to match the live renderer.
- [ ] `fitHourHeight` multiplies by `1.02` (§7.3) — easy to drop; without it autoscroll-at-edge breaks.
- [ ] Grid `slotMinutes` (live) vs `slotHeight`/`slotCount` (frozen) asymmetry during pinch (§9).

---

## Appendix — Function → file:line index
- Top/bottom inset: TimelineView.swift:501-508
- Now-line clamp: 520-533 ; SwiftUI now view 4578-4599 ; Canvas now 4634-4658 ; nowIndicatorYOffset 4757-4764
- Legend slot minutes: 536-541 ; legend label hide 544-555
- Pinch: direction 559-573 ; afterScale 576-588 ; resistance 591-612 ; fit 630-645 ; effectiveMin 658-672 ; anchorHours 681-690 ; adjustedScrollY 695-703 ; visualScale 706-716 ; handler 1625-1704
- Block render: blockX/width 3833-3850 ; blockY/height 3903-3957 ; pinch canvas 4626-4744
- Grid: 4855-4890
- contentHeight/slotHeight/timelineHeight/totalHeight: 1216-1325, 4749-4755
- Mapping fns (visibleStart/End, totalVisibleHours, fractions, yPosition, dateFromY): TimelineEditMapping.swift:81-274
- Boundary extension trigger: TimelineEditMapping.swift:165-194 ; override TimelineView.swift:1250-1268 ; hints 2718-2752 ; scroll comp CalendarPageView.swift:637-674
- Overlap topology: CalendarLayout.swift:331-848
- yOffset/eventHeight/occurrence filtering: CalendarLayout.swift:118-273 ; timelineVisibleOccurrences 185-242
- Interrupt/compound geometry: EventBlock.swift:264-516
- Day pager: TimelineView.swift:326-468 ; CalendarPageView.swift:170-178, 2265-2269, 2666-2676
- hourHeight constants/clamp: CalendarViewState.swift:11-78 ; box TimelineEditMapping.swift:10-33
