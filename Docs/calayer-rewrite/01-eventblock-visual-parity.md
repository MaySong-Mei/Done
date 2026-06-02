# EventBlock Visual Parity Spec

Baseline for the UIKit + CALayer rewrite of `EventBlock`. Goal: ZERO visual
behavior change. Every value here is copied verbatim from source. The rewrite
must satisfy each checklist item.

Primary source: `Done/Views/Calendar/Components/Timeline/Event/EventBlock.swift`
Supporting: `Done/Views/Calendar/Components/Timeline/Event/DiagonalHatchingPattern.swift`,
`Done/Views/Calendar/Components/Timeline/TimelineEditMapping.swift`.

Conventions: all colors are SwiftUI `Color`. `color` = the event's primary
type color (a prop, `EventBlock.color`, file:2088). `style.fillOpacity = 0.4`,
`style.strokeOpacity = 0.7`, `style.strokeWidth = 1.2` (file:224-226).
`Color(.systemBackground)` = dynamic system background.

---

## 0. View composition / layer order (bottom → top)

The body is a `GeometryReader` whose content is `bodyContent(blockWidth, blockHeight)`
(file:2466-2468). The reported `geo.size` is the post-`.frame` size set by the
parent. `renderedBlockHeight = resizeHeight(baseHeight: blockHeight)` (file:2588).

`bodyContent` builds `baseVisual` = `content(...)` then layers modifiers. The
EXACT stacking order (file:2670-2952), each as a separate compositing layer:

1. `content(...)` text (inside its own frame).  [§9]
2. `.frame(width: blockWidth, height: renderedBlockHeight, alignment: .topLeading)` (file:2675-2679).
3. `.background(blockBackground(usesNativeShapeMask:))` — fill (system bg + color@0.4).  [§1]
4. `.overlay` diagonal hatch if `isTimerActive`.  [§6]
5. `.overlay` agentic analyzing gradient if `isAgenticAnalyzing`.  [§7a]
6. `.overlay(.topTrailing)` multi-type triangle if `showsMultiTypeIndicator`.  [§8]
   — steps 3-6 + the text constitute `baseVisual`.
7. `baseVisual.mask(blockVisualMask)` — clips EVERYTHING above to block silhouette.  [§3]
8. `.overlay(blockBorderOverlay)` — stroke + effort bar (NOT masked by step 7).  [§2, §10]
9. `.overlay` todo border if `event.kind == .todo && !event.isDone`.  [§4]
10. `.overlay` resize handle capsules (ZStack), opacity-gated.  [§11]
11. `.overlay(.topTrailing)` agentic spinner if `isAgenticAnalyzing`.  [§7b]
12. `.frame(width: blockWidth, height: renderedBlockHeight)` (file:2816-2819).
13. `.scaleEffect(calendarEventBlockScale(...))` — currently ALWAYS 1.0.  [§12a]
14. `.opacity(isDimmedByFocus ? 0.28 : 1.0)`.  [§13]
15. `.shadow(radius: (isFocused || isInDragState) ? 3 : 0)`.  [§5]
16. `.offset(x: moveOffsetX during move, y: resize Y during resize)`.  [§12b]
17. `.contentShape(CalendarEventBlockInteractionShape)`.  [§14]
18. `.overlay` drag gesture (UIViewRepresentable, no visual).
19. `.onTapGesture`.
20. `.animation(.easeInOut(duration: 0.15), value: isInDragState)`.

Then OUTSIDE `bodyContent`, in `body` (file:2469-2511):

21. `.opacity(opacityForDisplayedDoneState)` — done-fade.  [§13]
22. `.overlay` absorption drop-target ring if `animatedDropTargetState`.  [§15]
23. `.scaleEffect(absorptionPulseScale * (animatedDropTargetState ? 1.03 : 1.0))`.  [§12c]

> NOTE the two `.scaleEffect`s and two `.opacity`s at different levels compose
> multiplicatively. CALayer rewrite must replicate the SAME nesting order or the
> mask/shadow relationships break (e.g. shadow is OUTSIDE the mask but INSIDE the
> dim-opacity; absorption ring is OUTSIDE everything in bodyContent).

---

## 1. Background fill  (file:2956-2972 `blockBackground`)

Two stacked fills inside a ZStack:
- Layer A: `Color(.systemBackground)` (opaque). Gives the block an opaque base so
  the color tint reads consistently over the grid.
- Layer B: `color.opacity(0.4)` (`blockFillOpacity`, file:2314-2316 → `style.fillOpacity`).

Shape selection driven by `usesNativeShapeMask` (file:2647 =
`compoundShape != nil || resolvedInterruptVisualMode == .embeddedMoat`):
- `usesNativeShapeMask == true`: both layers are plain `Rectangle()` (full frame).
  Final silhouette comes from the `.mask` in step 7 (§3).
- `usesNativeShapeMask == false`: both layers are
  `RoundedRectangle(cornerRadius: interruptCornerRadius, style: .continuous)`.

`interruptCornerRadius` (file:2292-2294): `5` if `event.isInterrupt`, else `6`.

- [ ] Opaque system-background base layer present.
- [ ] color-tint layer at exactly opacity 0.4.
- [ ] corner radius 6 (normal) / 5 (interrupt event), `.continuous` curve.
- [ ] rectangle (not rounded) base when masked by compound/embedded shape.

---

## 2. Border / stroke  (file:2992-3006 `blockBorderOverlay`)

Single stroke, NOT inside the mask (overlay applied after `.mask`):
- color = `color.opacity(0.7)` (`blockStrokeOpacity` → `style.strokeOpacity`, file:2318-2320).
- lineWidth = `blockStrokeWidth` (file:2322-2324):
  - interrupt event: `max(0.8, 1.2 + 0.2)` = **1.4**
  - normal: **1.2**
- Shape, in priority order (file:2997-3006):
  - `compoundShape` present → `compoundShape.stroke(...)`.
  - else `embeddedMoat` mode → `embeddedInterruptCardShape(cornerRadius: interruptCornerRadius)`
    which is `RoundedRectangle(cornerRadius:, style: .continuous)` (file:2310-2312).
  - else → `RoundedRectangle(cornerRadius: interruptCornerRadius, style: .continuous)`.
- `.allowsHitTesting(false)` (file:2741).

Note: SwiftUI `.stroke` centers the line on the path edge (half in/half out). CALayer
`borderWidth` is inset; rewrite must draw a centered stroke via a `CAShapeLayer`
to match (a `borderWidth` will look thinner/sharper).

- [ ] stroke color `color@0.7`.
- [ ] lineWidth 1.2 normal / 1.4 interrupt.
- [ ] stroke shape follows compound / embedded / rounded variant.
- [ ] stroke centered on edge (not inset).

---

## 3. Block silhouette mask  (file:2974-2989 `blockVisualMask`)

White fill of one of (priority order):
- `compoundShape` (a `CalendarInterruptParentCompoundShape`) — see §16.
- `embeddedMoat` mode → `embeddedInterruptCardShape(cornerRadius: interruptCornerRadius)`
  = `RoundedRectangle(cornerRadius: interruptCornerRadius, style: .continuous)`.
- else → `RoundedRectangle(cornerRadius: interruptCornerRadius, style: .continuous)`.

Masks `baseVisual` (background fill + hatch + agentic gradient + multi-type triangle + text).
The border (§2), todo border (§4), handles (§11), spinner (§7b) are applied AFTER the
mask and are NOT clipped by it (except the multi-type triangle, which IS inside baseVisual
and therefore clipped — see §8).

- [ ] mask is a hard alpha clip (white = keep), `.continuous` corner style.
- [ ] compound silhouette path used when `compoundShape != nil`.

---

## 4. Todo border  (file:2743-2757, color at 2575-2582)

Shown only when `event.kind == .todo && !event.isDone`.
- Shape: `RoundedRectangle(cornerRadius: interruptCornerRadius, style: .continuous)`.
- `.strokeBorder(todoBorderColor, lineWidth: 1)` — note `strokeBorder` = INSET stroke
  (fully inside the path edge), unlike §2's centered `.stroke`.
- Sits ON TOP of `blockBorderOverlay` (§2). `.allowsHitTesting(false)`.

`todoBorderColor` (file:2575-2582) — urgency ramp, evaluated against `Date()` (now):
- not a todo OR done → `Color.white.opacity(0.45)` (but only drawn when todo & !done).
- todo, no `event.deadline` → `Color.white.opacity(0.45)` (default subtle).
- `deadline < now` (OVERDUE) → `Color.red.opacity(0.9)`.
- `deadline - now < 24*3600` (within 24h, APPROACHING) → `Color.orange.opacity(0.9)`.
- else (deadline > 24h out) → `Color.white.opacity(0.45)`.

- [ ] todo border only when todo & not done.
- [ ] lineWidth 1, INSET (strokeBorder semantics).
- [ ] default `white@0.45`; overdue `red@0.9`; <24h `orange@0.9`.
- [ ] threshold exactly 24*3600 s; overdue test is strict `<` now.

---

## 5. Shadow  (file:2828)

`.shadow(radius: (isFocused || isInDragState) ? 3 : 0)`.
- radius 3 when `isFocused` OR `isInDragState`, else 0 (no shadow).
- SwiftUI default shadow: color = `Color.black.opacity(1/3)`, offset `(0, 0)` (radius-only).
  CALayer rewrite: `shadowColor=black, shadowOpacity≈0.333, shadowRadius=3, shadowOffset=.zero`.
- Applied OUTSIDE the mask, INSIDE the dim-opacity. So shadow follows the un-masked
  rectangular/rounded frame bounds (it is on the post-mask composited layer).

`isInDragState` (file:2239-2241) = `isLongPressing || isDragging || isFollowingExternalDrag`.

- [ ] radius 3 iff focused or in-drag-state; else 0.
- [ ] black @ ~0.333, zero offset.

---

## 6. Diagonal hatch (timer active)  (file:2685-2691; shape file:DiagonalHatchingPattern.swift)

Shown only when `isTimerActive` (prop, file:2143).
- `DiagonalHatchingPattern(spacing: 6, lineWidth: 1).stroke(color.opacity(0.3), lineWidth: 1)`.
- `.allowsHitTesting(false)`. Inside baseVisual → clipped by mask (§3).
- Geometry (DiagonalHatchingPattern.path): diagonal lines bottom-left→top-right at 45°.
  - `totalLength = rect.width + rect.height`.
  - `offset` starts at `-rect.height`, each line: move `(offset, rect.height)` → line `(offset + rect.height, 0)`.
  - increment `offset += spacing` (6) while `offset < totalLength`.
  - Lines are exactly 45° (slope -1), spaced 6pt apart horizontally.

- [ ] only when timer active.
- [ ] stroke `color@0.3`, lineWidth 1, spacing 6.
- [ ] 45° lines covering full rect, generated from -height to width+height.
- [ ] clipped to block silhouette.

---

## 7. Agentic analyzing overlays

`isAgenticAnalyzing` (file:2254-2261) = `agenticProcessingPhase ∈ {.queued, .analyzing}`.

### 7a. Shimmer gradient  (file:2692-2709)
- `Rectangle().fill(LinearGradient(...))` inside baseVisual (clipped by mask).
- Gradient colors (3 stops): `white@0.05`, `white@0.22`, `white@0.05`.
- `startPoint: .topLeading`, `endPoint: .bottomTrailing` (diagonal).
- `.opacity(isInDragState ? 0.08 : 0.18)` — extra opacity multiplier on the whole gradient.
- `.allowsHitTesting(false)`.

> NOTE: this is a STATIC gradient (no animated shimmer phase in the gradient itself);
> the "shimmer" perception comes from the spinner (§7b). No keyframe animation here.

### 7b. Spinner overlay  (file:2805-2814)
- `.overlay(alignment: .topTrailing)`: `ProgressView().progressViewStyle(.circular).controlSize(.small)`.
- `.padding(5)` → `.background(.ultraThinMaterial, in: Circle())` → `.padding(5)`.
  So: 5pt inner padding around the spinner, a circular ultraThinMaterial backing, then
  5pt outer padding offsetting it from the top-right corner.
- `.allowsHitTesting(false)`. Applied AFTER the mask → NOT clipped.

- [ ] gradient stops white 0.05/0.22/0.05, topLeading→bottomTrailing.
- [ ] gradient layer opacity 0.08 in-drag / 0.18 otherwise.
- [ ] spinner top-right, small circular, ultraThinMaterial circle backing, 5+5 padding.
- [ ] both only when queued/analyzing.

### 7c. Failed badge (related, file:2916-2937, 2267-2268)
- Not a separate layer: when `isAgenticFailed` (`phase == .failed`), `displayTitle`
  becomes `"⚠️ " + event.title` while `isFailedBadgeVisible` is true.
- On appear / on `isAgenticFailed → true`: set `isFailedBadgeVisible = true`, then after
  `5s` `withAnimation(.easeOut(duration: 0.4))` set it false (the ⚠️ prefix fades from the title).

- [ ] title gains "⚠️ " prefix for 5s on failure, then animates away (0.4s easeOut).

---

## 8. Multi-type corner triangle  (file:2710-2727; shape file:3141-3149)

Shown only when `showsMultiTypeIndicator` (prop, file:2095).
- `.overlay(alignment: .topTrailing)`: `MultiTypeCornerTriangle().fill(Color.primary.opacity(0.28)).frame(width: 14, height: 14)`.
- `.allowsHitTesting(false)`. Inside baseVisual → CLIPPED by mask (follows corner radius).
- `Color.primary` adapts to light/dark automatically (black-ish in light, white-ish in dark).
- `MultiTypeCornerTriangle.path` (file:3142-3148): right-isoceles triangle, right angle at
  top-right. Points: `(minX,minY) → (maxX,minY) → (maxX,maxY)`, closed. Hypotenuse
  top-left→bottom-right. 14×14 frame in the top-right corner.

- [ ] only when showsMultiTypeIndicator.
- [ ] 14×14 triangle, `Color.primary @ 0.28`, right-angle top-right.
- [ ] clipped to block silhouette (so it follows the rounded corner).

---

## 9. Text content  (file:3040-3132 `content`; layout fn file:672-782)

Text only rendered when `showText` (file:2109) is true AND a non-nil `CalendarEventTextLayout`
is produced. Otherwise `Color.clear` (file:3130).

### 9a. Layout / fit gate  (`calendarEventTextLayout`, file:672-782)
Returns nil (NO text) unless `bounds.width >= 28 && bounds.height >= 16` (file:682).
Insets (`calendarEventBlockInsets`, file:654-661): `compact = isWeekMode || isThreeDayMode`:
- leading: compact 6 / normal 12
- trailing: compact 4 / normal 8
- vertical: compact 4 / normal 8

`titleFontHeight` = `UIFont.systemFont(ofSize: baseFontSize, weight: .semibold).lineHeight`.
`needsCenter` = `bounds.height < verticalInset*2 + titleFontHeight` (file:691). When true,
content y = `bounds.minY` and height = full `bounds.height`, vertical alignment `.leading`
(centered vertically); else y = `minY + verticalInset`, height = `height - verticalInset*2`,
alignment `.topLeading` (file:3120-3124).

`contentRect` x = `minX + leading`, width = `width - leading - trailing` (file:692-697).
Returns nil if contentRect width/height <= 0 (file:698-700).

`titleLineLimit` (file:702-707):
- `bounds.width < 48`: height>=40 → 3, height>=28 → 2, else 1.
- `bounds.width >= 48`: 2.

### 9b. Fonts / sizes
- `titleFontSize = resolvedTitleFontSize` (file:2185-2188): `clamp(titleFontSizeSetting, 9, 16)`.
  `@AppStorage(calendarEventFontSize)` default = `calendarEventTitleFontSizeDefault = 12` (file:634).
- `timeFontSize = calendarEventTimeFontSize(titleFontSize, isWeekMode)` (file:639-642):
  `ratio = isWeekMode ? 7/12 : 8/12`; `max(7, round(titleFontSize * ratio))`. (At default 12 →
  week 7, otherwise 8.)
- `titleSpacing = calendarEventBlockTitleSpacing` (file:667-670): compact 1 / normal 2.

### 9c. Title  (file:3082-3088)
- `Text(displayTitle)` (`displayTitle` = event.title, or "⚠️ "+title during failed badge).
- `.font(.system(size: titleFontSize, weight: .semibold))`, `.foregroundStyle(.primary)`.
- `.lineLimit(textLayout.titleLineLimit)`, `.multilineTextAlignment(.leading)`,
  `.allowsTightening(true)`, `.frame(maxWidth: .infinity, alignment: .leading)`.

### 9d. Multi-type subtitle  (file:3101-3109) — only if `showsMultiTypeIndicator`
- `Text(multiTypeSubtitleText)` = `event.effectiveTypes` (non-empty), primary first,
  joined by `" · "`; empty if <2 types (file:2278-2282).
- `.font(.system(size: timeFontSize, weight: .medium))`, `.foregroundStyle(.primary)`,
  `.opacity(0.55)`, `.lineLimit(1)`, `.truncationMode(.tail)`, leading-aligned.

### 9e. Time range  (file:3111-3118) — only if `textLayout.showsTimeRange` & `adjustedDisplayRange != nil`
- `Text("<start> - <end>")` using `Self.timeFormatter` (24h `HH:mm` or 12h, per locale; file:2331-2348).
- `.font(.system(size: timeFontSize, weight: .medium).monospacedDigit())`,
  `.foregroundStyle(.secondary)`, `.lineLimit(1)`, leading-aligned.
- During resize/move, the displayed times reflect `adjustedDisplayRange` (live drag range).

`showsTimeRange` gate (file:723-766):
- If `showTimeBelowTitleSetting` (`@AppStorage`, DEFAULT true, file:2183): show iff
  `bounds.width >= 48 && bounds.height >= (needsCenter ? 0 : verticalInset*2) + titleFontHeight + spacing + timeFontHeight`.
- else (legacy): require `style.showTimeRange` AND `width >= 88 && height >= 42`.
- AND if `(requireTitleFit || showTimeBelowTitle)` and showing time would clip the title
  (`!titleFits(showsTime: true)`), drop the time row (file:764-766).

> There is NO explicit per-pt opacity fade ramp (e.g. "14-22pt") in this file. The
> "fade-out" of text on shrinking blocks is achieved structurally: the time row and
> then the title are DROPPED (returns nil layout) once the block is too short, via the
> width/height gates above (28×16 floor, the 48/88 width gates, line-limit collapse,
> and the titleFits checks). Rewrite must reproduce these GATES exactly — there is no
> alpha ramp to port.

- [ ] no text below 28w × 16h.
- [ ] insets compact 6/4/4, normal 12/8/8.
- [ ] vertical-center when height < 2*vInset + titleLineHeight.
- [ ] title semibold @ titleFontSize, primary, line limit per 9a, leading, tightening on.
- [ ] subtitle medium @ timeFontSize, primary @ 0.55, 1 line, tail-truncate (only multi-type).
- [ ] time medium monospaced-digit @ timeFontSize, secondary, 1 line.
- [ ] time-show gate honors showTimeBelowTitle (default ON) geometric path vs legacy 88×42.
- [ ] title/time use live adjustedDisplayRange during drag.

---

## 10. Effort left-bar  (file:3008-3027, inside `blockBorderOverlay`)

Shown when `event.colorDepth > 0`.
- A `Rectangle().fill(color)` masked twice: first by `blockVisualMask` (block silhouette),
  then by `Rectangle().frame(width: barWidth)` aligned `.leading`. Net: a solid `color`
  strip down the left edge, top/bottom following the rounded corners.
- `barWidth` (file:3013-3015):
  - week mode: `1.0 + colorDepth * 1.5` (range ~1.0→2.5pt as depth 0→1; comment "1.3→2.5")
  - otherwise: `1.5 + colorDepth * 2.5` (range 1.5→4.0pt; comment "1.7→4")
- `colorDepth` documented range 0.2–1.0.

- [ ] left bar only when colorDepth > 0.
- [ ] full-opacity `color` (no opacity reduction).
- [ ] width formula week `1.0 + depth*1.5`, else `1.5 + depth*2.5`.
- [ ] bar clipped to block silhouette (rounded top/bottom).

---

## 11. Resize handle capsules  (file:2758-2804)

Container: `ZStack(alignment: .topLeading)` with `.opacity(showHandles ? 1 : 0)`
(opacity-gated, NOT conditionally removed — structural stability requirement, file:2759-2762).
`.allowsHitTesting(false)`.

`showHandles` (file:2763-2767) = `isDragEnabled && renderedBlockHeight >= 32 &&
calendarShouldShowResizeHandles(style, showsResizeHandles, isLongPressing)`.
- `calendarShouldShowResizeHandles` (file:926-932) = `style == .edit || showsResizeHandles || isLongPressing`.
- `isDragEnabled` (file:2350-2360) = any of onDragEnded/onResizeTopEnded/onResizeBottomEnded non-nil.

Top handle (if `canResizeTop`, file:2771-2784):
- `Capsule().fill(color.opacity(isResizingTop ? 0.8 : 0.45 * resizeHandleOpacity))`.
  - `resizeHandleOpacity` prop default 1 (file:2128).
- `.frame(width: isResizingTop ? activeWidth : placement.width, height: 3)`.
- `.position(x: placement.centerX, y: 5 + 1.5)` → y = 6.5.

Bottom handle (if `canResizeBottom`, file:2785-2798):
- same fill rule with `isResizingBottom`.
- `.frame(width: isResizingBottom ? activeWidth : placement.width, height: 3)`.
- `.position(x: placement.centerX, y: renderedBlockHeight - 5 - 1.5)` → y = height - 6.5.

`isResizingTop` = `isInDragState && currentDragMode == .resizeTop` (file:2768);
`isResizingBottom` analogous (file:2769).

`placement` (`calendarResizeHandlePlacement`, file:838-865):
- `segmentWidth` = compoundGeometry first(top)/last(bottom) visible segment width, else viewWidth, clamped [0, viewWidth].
- `availableWidth = max(4, segmentWidth)`.
- `baseHandleWidth = min(viewWidth * 0.4, 36)`.
- `width = min(baseHandleWidth, max(4, availableWidth - 4))`.
- `centerX = availableWidth / 2`.

`activeWidth` (when resizing, file:2773-2776 / 2787-2790):
`min(max(width, availableWidth*0.7), max(width, availableWidth - 4))`.

Animations: `.animation(.easeOut(duration: 0.2), value: isResizingTop)` and
`value: isResizingBottom` (file:2801-2802) — width + fill animate on resize start.

- [ ] handles container opacity 0/1 gated by showHandles (never removed).
- [ ] capsule height 3, width = placement.width (idle) / activeWidth (resizing).
- [ ] fill `color@(resizing 0.8 : 0.45*resizeHandleOpacity)`.
- [ ] top y=6.5, bottom y=height-6.5, centerX = availableWidth/2.
- [ ] width caps: base min(viewWidth*0.4, 36); active per formula.
- [ ] only when height>=32, drag-enabled, and edit/showsResizeHandles/longPressing.
- [ ] 0.2s easeOut on resize-state width/fill change.

---

## 12. Transforms (scale / offset)

### 12a. Block scale  (file:2820-2826) — `calendarEventBlockScale`
`calendarEventBlockScale(isMoveDragging:isFocused:isDimmedByFocus:)` (TimelineEditMapping.swift:276-283)
**currently returns a constant `1`** (all args ignored). So this scaleEffect is a NO-OP today.
- [ ] block scale = 1.0 always (the fn body is `return 1`). PRESERVE as no-op — do not
      reintroduce focus/drag scaling here.

### 12b. Drag offset  (file:2831-2832)
`.offset(x: currentDragMode == .move ? moveOffsetX : 0, y: (isDragging && dragMode != .move ? resizeYOffset(baseHeight) : 0))`.
- `moveOffsetX` (file:2388-2392) = `effectiveDragOffset.x` when in-drag & move, else 0.
- `resizeYOffset` (file:2419-2424) = for resizeTop only: `min(snappedResizeOffset, baseHeight - hourHeight/2)`; else 0.
- The block HEIGHT during resize comes from `resizeHeight` (file:2372-2383): resizeTop
  `max(20, base - snappedResizeOffset)`, resizeBottom `max(20, base + snappedResizeOffset)`.
  `snappedResizeOffset` (file:2366-2369) = `round(dragOffset.y / snapSize) * snapSize`,
  `snapSize = hourHeight/4` (15-min). minHeight floor 20pt.
- [ ] move drag: x offset = finger x; resizeTop: y offset = clamped snapped offset.
- [ ] resize height recomputed with 15-min snap, floor 20pt.

### 12c. Absorption pulse + drop-target scale  (file:2482, 2514-2531)
- `.scaleEffect(absorptionPulseScale * (animatedDropTargetState ? 1.03 : 1.0))`.
- Drop-target steady scale = **1.03** while `animatedDropTargetState` (eased in §15).
- Pulse (`triggerAbsorptionPulse`, file:2522-2531): `withAnimation(.easeOut(duration: 0.12))`
  scale → **1.08**; after 0.12s, `withAnimation(.spring(response: 0.35, dampingFraction: 0.55))`
  scale → 1.0. Triggered on `isRecentlyAbsorbedInto` becoming true (and on appear if already true).
- [ ] drop-target scale 1.03 (eased over 0.15s with the ring).
- [ ] pulse: 1.08 over 0.12s easeOut, then spring(0.35, 0.55) back to 1.0.
- [ ] these multiply with §12a (which is 1.0) at the OUTER body level.

---

## 13. Opacity (done / deferred / dim)

### 13a. Done-todo fade  (file:2469, 2546-2565)
`.opacity(opacityForDisplayedDoneState)` (outer body level).
- `event.kind != .todo` → 1.0 always (events stay vivid past/future — design bedrock #7).
- todo: `displayedDoneState ?? event.isDone` → done ? **0.55** : 1.0.
- `displayedDoneState` lags `event.isDone`: first appear snaps (no anim); later appears with
  stale state animate `withAnimation(.easeInOut(duration: 0.4))` (file:2556-2565). Also re-synced
  on `event.isDone` change (file:2502-2504).
- [ ] todo done → block opacity 0.55, else 1.0; events always 1.0.
- [ ] fade animates 0.4s easeInOut on re-appearance / isDone change; first appear snaps.

### 13b. Focus dim  (file:2827)
`.opacity(isDimmedByFocus ? 0.28 : 1.0)` (inside bodyContent, on the masked+shadowed layer).
- `isDimmedByFocus` (file:2243-2245) = `isFocusContextActive && !isFocused`.
- [ ] dim to 0.28 when a focus context is active and this block isn't the focused one.
- [ ] dim opacity nests INSIDE the done-fade (they multiply: 0.55*0.28 possible).

---

## 14. Hit-test / content shape  (file:2833-2839, 2051-2079)

`.contentShape(CalendarEventBlockInteractionShape(compoundShape:, cornerRadius: interruptCornerRadius, verticalEdgeInset: showsResizeHandles ? 0 : 6))`.
- `CalendarEventBlockInteractionShape.path` (file:2063-2078):
  - `cappedInset = calendarFallThroughEdgeInset(maxInset: verticalEdgeInset, height: rect.height)`.
  - smoothstep (file:1000-1009): below 12pt → 0; above 32pt → maxInset(6); between → `maxInset * (t*t*(3-2t))` with `t=(h-12)/20`.
  - `hitRect = inset by (0, cappedInset)`; path = compoundShape.path(hitRect) or RoundedRectangle.
- The matching UIView (`ExtendedHitAreaView`) uses the SAME inset fn plus
  `verticalExtension = outerEdgeThreshold` (resize reach beyond bounds). Excluded hit rects =
  compound cutout rects (`gestureExcludedHitRects`, file:2636) so touches over a cutout fall through.
- [ ] content shape = block silhouette inset top/bottom by smoothstep(0→6) over height 12→32pt.
- [ ] verticalEdgeInset 0 when handles shown, else 6.
- [ ] compound cutout rects excluded from hit area.

---

## 15. Absorption drop-target ring  (file:2470-2496)

Outer body overlay, shown when `animatedDropTargetState` (animated mirror of `isAbsorptionDropTarget`).
- `RoundedRectangle(cornerRadius: interruptCornerRadius, style: .continuous).strokeBorder(Color.accentColor, lineWidth: 2.5)`.
- `.allowsHitTesting(false)`.
- Mirror update: `.onChange(of: isAbsorptionDropTarget)` → `withAnimation(.easeInOut(duration: 0.15)) { animatedDropTargetState = new }` (file:2492-2496); initial value set on appear (file:2485).
- Pairs with the 1.03 scale in §12c (both keyed on `animatedDropTargetState`, animated together).
- [ ] accentColor ring, lineWidth 2.5, INSET (strokeBorder), `.continuous`, corner = interruptCornerRadius.
- [ ] appears/disappears with 0.15s easeInOut, mirroring isAbsorptionDropTarget.
- [ ] outermost overlay (above done-fade); not hit-testable.

---

## 16. Compound interrupt shape & geometry

`compoundShape` exists only when `shouldRenderCompoundInterruptParentShape` (file:1056-1064 =
`isCompoundParentEvent`, i.e. `!interruptEmbeddedChildRanges.isEmpty`, file:2306-2308) AND the
computed geometry has non-empty cutouts (file:2626-2635). cornerRadius = `max(interruptCornerRadius, 6)`.

### 16a. Moat widths
- `calendarInterruptMoatWidthHorizontal` → **3** (constant, file:250-255).
- `calendarInterruptMoatWidthVertical` → **2** (constant, file:257-262).
- `needsMoat` = embeddedMoat mode OR compound parent (file:2594-2595).

### 16b. Overlay / cutout geometry  (file:269-293)
- `calendarInterruptOverlayGeometry(parentWidth)`: `leadingInset = 8`; width = `max(0, parentWidth-8)`,
  xOffset = `min(8, parentWidth)`.
- `calendarInterruptCutoutGeometry(parentWidth, moatWidth)`: xOffset = `max(0, 8 - moatWidth)`;
  width = `max(0, parentWidth - xOffset)`. (With horizontal moat 3 → cutout xOffset = 5.)

### 16c. Compound cutout rects  (`calendarInterruptParentCompoundGeometry`, file:355-516)
- `mergedRanges` = child ranges clipped to parent, sorted, overlapping merged (file:327-353).
- For each merged range: `topProgress = (range.start - parentStart)/totalDuration`;
  `segmentProgress = (range.end - range.start)/totalDuration`.
  - `rawTop = parentHeight*topProgress - verticalGap(2)`; `top = max(0, rawTop)`.
  - `rawHeight = parentHeight*segmentProgress + verticalGap*2`;
    `height = min(max(verticalGap*2 + 2, rawHeight), max(0, parentHeight - top))` → min visible 6pt.
  - rect = `(x: cutout.xOffset, y: top, width: cutout.width, height)`.
- Rects sorted by minY, then vertically-overlapping rects merged into one (file:405-421).
- `cutout.hasTopLobe = rect.minY > 0.5`; `hasBottomLobe = rect.maxY < parentHeight - 0.5`.

### 16d. Visible segments (silhouette + text rects)
- `spineWidth = max(0, cutout.xOffset)` (the narrow left "spine" beside a cutout).
- Walk cutouts top→bottom: full-width segments (`fullWidth = parentWidth`) between cutouts;
  spine-width segments over cutout spans (file:436-466). Fallback full-rect segment if empty.
- Adjacent segments with equal width (±0.5) and contiguous y (±0.5) merged (file:478-494).
- `contentRects` = one rect per normalized segment (x:0, width = segment.width).
- `CalendarInterruptParentCompoundShape.path` (file:2007-2049): builds a closed polygon from
  segment widths/yEnds (left edge straight at minX, right edge stepping in/out at width changes),
  rounded via `calendarRoundedClosedPolygonPath(points, cornerRadius)` (file:867-922) — per-vertex
  quad-curve rounding clamped to half the adjacent edge lengths.

### 16e. Stack-peek cover bands (TEXT ONLY)  (file:528-630)
- `calendarStackPeekTextGeometry`: applies only when `!isInterruptEvent && !stackPeekCoverRanges.isEmpty
  && stackPeekStripWidth > 0` (file:2653-2669). Produces `textGeometry`, used ONLY for fitting
  the title/time. **Does NOT change the silhouette, mask, border, or hit-test** — `compoundGeometry`
  (unaugmented) drives those.
- Cover ranges projected to y-bands; intersecting segment spans shrink width to
  `min(segment.width, clampedStripWidth)` where `clampedStripWidth = max(0, min(peekStripWidth, parentWidth))`.
- There is NO visible "cover band" drawn by EventBlock; the higher-depth sibling block is what
  actually paints on top (z-order, handled by the parent layout). This block merely keeps its text
  out of the covered region.

- [ ] compound shape only for parents with children & non-empty cutouts; corner max(interruptCR,6).
- [ ] horizontal moat 3, vertical moat 2 (constants).
- [ ] leadingInset 8; cutout xOffset = 8 - hMoat (=5); spine width = xOffset.
- [ ] cutout rects from child-range progress, min visible height 6pt, top pulled up 2pt.
- [ ] overlapping cutouts merged; segments built full-width vs spine-width; rounded polygon.
- [ ] stack-peek only shrinks TEXT rects (no silhouette/border/visible-band change).

---

## 17. Animations summary (durations / curves to preserve)

| Trigger | Animation | file |
|---|---|---|
| drop-target ring + 1.03 scale | easeInOut 0.15 | 2493 |
| absorption pulse up → 1.08 | easeOut 0.12 | 2523 |
| absorption pulse → 1.0 | spring(response 0.35, damping 0.55) | 2527 |
| done-fade | easeInOut 0.4 | 2561 |
| failed badge fade-out (after 5s) | easeOut 0.4 | 2921/2932 |
| resize handle width/fill | easeOut 0.2 | 2801-2802 |
| long-press began (isLongPressing/dragMode) | easeOut 0.15 | 2857 |
| in-drag-state body | easeInOut 0.15 | 2912 |

- [ ] all durations/curves above reproduced.

---

## 18. Constants quick-reference

- fillOpacity 0.4 · strokeOpacity 0.7 · strokeWidth 1.2 (interrupt 1.4) — 224-226, 2322
- corner radius: normal 6, interrupt 5; compound max(.,6) — 2293, 2632
- title font default 12, clamp [9,16], semibold — 634, 2185
- time font = max(7, round(title * (week 7/12 | 8/12))), medium monospaced-digit — 639
- insets compact 6/4/4, normal 12/8/8; title-spacing compact 1 / normal 2 — 654, 667
- text min block 28w×16h; width gates 48 / legacy 88×42 — 682, 703, 730
- done-todo opacity 0.55; focus-dim 0.28 — 2549, 2827
- drop-target scale 1.03; pulse 1.08; block-scale const 1.0 — 2482, 2524, TEM:282
- shadow radius 3 (focus/drag) — 2828
- handle height 3, top y 6.5 / bottom y h-6.5, width min(w*0.4,36); fill 0.8 / 0.45*op — 2778-2796
- diagonal hatch spacing 6, lineWidth 1, color@0.3 — 2687
- agentic gradient white 0.05/0.22/0.05, layer opacity 0.08(drag)/0.18 — 2698-2706
- multi-type triangle 14×14, primary@0.28 — 2723-2724
- todo border lineWidth 1; white@0.45 / orange@0.9(<24h) / red@0.9(overdue) — 2754, 2579
- absorption ring lineWidth 2.5 accentColor — 2478
- moat horizontal 3 / vertical 2; leadingInset 8 — 254, 261, 273
- fall-through hit inset smoothstep 12→32pt, max 6 — 997-1009
