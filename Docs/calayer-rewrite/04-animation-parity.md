# 04 — Animation & Transition Parity Spec

Scope: every animation/transition surface on the **calendar canvas timeline**
(not the in-event detail timeline, which is a separate widget — see "Adjacent /
out of scope" at the bottom). The goal is a UIKit + CALayer port with **zero
behavior change**, so each section gives the SwiftUI trigger, the animated
property, the exact curve/duration, and the proposed CALayer equivalent.

Primary files:
- `Done/Views/Calendar/Components/Timeline/TimelineView.swift`
- `Done/Views/Calendar/Components/Timeline/Event/EventBlock.swift`
- `Done/Views/Calendar/Components/Timeline/TimelineEditMapping.swift`
- `Done/Views/Calendar/CalendarPageView.swift` (timeline-owning parent; hosts focus / grace-resize / range-mode / boundary-extension / absorb-bubble animations)

---

## Cross-cutting lesson: `.animation()` as a transaction boundary (issue #12)

The codebase is **deliberately architected** so that no animation is attached at
the root of `EventBlock`. Two comment blocks make this explicit:

- `EventBlock.swift:2472-2475` — drop-target highlight reads a `@State` mirror
  (`animatedDropTargetState`), animated by a scoped `withAnimation` inside
  `.onChange`, "so the animation is scoped to this overlay + the scaleEffect …
  no root-level `.animation(value:)` modifier that could animate unrelated body
  changes in the same frame."
- `EventBlock.swift:2515-2519` — same rationale for the absorption pulse mirror.

Why this matters for the port: in SwiftUI, a single `.animation(_, value:)` is a
**transaction boundary** — every property that changes in the same render pass
gets animated, which is exactly the 200–400ms layout-spike footgun from issue
#12 (a conditional view toggle dragging an unrelated layout change into a long
implicit animation). The CALayer port reproduces the *feel* only if it mirrors
this scoping discipline:

- **Do NOT** wrap a whole layer-tree mutation in one `CATransaction` with a long
  duration. Each distinct animation below must be its own `CATransaction`
  (begin/commit) or its own explicitly-added `CA*Animation` on the **specific
  sublayer/keypath** it owns.
- Frame/position changes that are NOT meant to animate (drag-follow, pinch
  stretch, scroll) must be wrapped in a `CATransaction` with
  `setDisableActions(true)` — the analog of the
  `transaction.disablesAnimations = true` used at `TimelineView.swift:1650-1652`.
- Layer-backed implicit animations (the default 0.25s `actions`) must be
  **disabled globally** on the timeline layers, then re-enabled per-animation,
  or you will get unwanted 0.25s eases on every `bounds`/`position` write.

---

## 1. Overlap-topology re-layout spring (staircase ↔ peer ↔ containment)

- **File/line:** `TimelineView.swift:3959-3968`
- **Trigger:** `value: slot` — the `CalendarLayout.EventOverlapSlot` (width
  fraction, x-offset fraction, zIndex) of a rendered occurrence changes because
  an adjacent drag re-shapes the overlap cluster.
- **Animated property:** the block's `.offset(x: blockX, y: blockY + 1.5)` and
  frame width (x/width derived from `slot.widthFraction` / `slot.xOffsetFraction`).
- **Curve:** `.spring(response: 0.25, dampingFraction: 0.85)`.
- **Critical exception:** `isDraggedOccurrence ? nil : …` — the **actively
  dragged** block has animation `nil` so its frame stays glued to the finger;
  only the *surrounding* events do the re-layout dance.
- **CALayer equivalent:** `CASpringAnimation` on `position` and `bounds.size`
  (keyPath `position`, `bounds`). Map SwiftUI spring → CASpringAnimation via
  `response`/`dampingFraction`: `stiffness = (2π/response)^2`,
  `damping = (4π·dampingFraction)/response`, `mass = 1`. So response=0.25,
  damping=0.85 → stiffness≈631.7, damping≈42.7, mass=1. Use
  `animation.duration = animation.settlingDuration`. For the dragged layer:
  set its `position` inside `CATransaction.setDisableActions(true)`.

## 2. Focus / preview-handle / grace-resize zIndex tiers

- **File/line:** `TimelineView.swift:3970-3985`
- **Trigger:** identity match against `focusedEventID`, `previewHandleEventID`,
  `graceResizeEventID`, plus interrupt-embedded boost.
- **Animated property:** `zIndex` (NOT animated — it's a discrete stacking value
  recomputed each layout). Base values: focused = 3, preview-handle = 2.5,
  grace-resize = 2, default = 0; then `+ slot.zIndex`; `+ 0.35` if the event's
  `interruptRelation.state == .embedded`.
- **Curve:** none on zIndex itself. The *visible* transition into/out of focus
  comes from the slot spring (§1), the shadow change (§3), and the focus-dim
  opacity (§3) — focus set/clear at `CalendarPageView.swift:3092` & `3107` are
  **bare assignments, not wrapped in `withAnimation`**.
- **CALayer equivalent:** map zIndex → `CALayer.zPosition` (set directly, no
  animation). Recompute and assign inside the same `setDisableActions(true)`
  transaction as the layout pass.

## 3. Focus shadow + focus-dim opacity + block scale

- **File/line:** `EventBlock.swift:2820-2828` (scale + dim + shadow), root
  `.animation(.easeInOut(duration: 0.15), value: isInDragState)` at `:2912`.
- **Triggers & properties:**
  - `.scaleEffect(calendarEventBlockScale(...))` — **NOTE: currently a no-op.**
    `TimelineEditMapping.swift:276-283` returns a hard-coded `1`. Port should
    keep `transform = identity` (do not reintroduce scale). Same no-op call also
    appears on `dragPreview` at `TimelineView.swift:4481-4487`.
  - `.opacity(isDimmedByFocus ? 0.28 : 1.0)` — non-focused blocks dim to 0.28
    while another block is focused.
  - `.shadow(radius: (isFocused || isInDragState) ? 3 : 0)` — drop shadow appears
    at radius 3 during focus or drag, else 0.
- **Curve:** the `.animation(.easeInOut(duration: 0.15), value: isInDragState)`
  at `:2912` animates these when `isInDragState` flips. Focus dim transitions
  ride whatever transaction the parent's focus assignment lands in (effectively
  the next runloop's default, since the assignment is unanimated — visually a
  ~0.15s-or-instant settle depending on coincident state).
- **CALayer equivalent:** `shadowOpacity`/`shadowRadius` via `CABasicAnimation`
  (easeInOut, 0.15s) keyed on the drag-state toggle; `opacity` via the same.
  Use `CAMediaTimingFunction(name: .easeInEaseOut)`.

## 4. Absorption pulse (1.0 → 1.08 → 1.0)

- **File/line:** `EventBlock.swift:2514`, `2522-2531`; applied at
  `.scaleEffect(absorptionPulseScale * (animatedDropTargetState ? 1.03 : 1.0))`
  on `:2482`.
- **Trigger:** event newly enters the recently-absorbed window
  (`isRecentlyAbsorbedInto` flips true via `.onChange` at `:2509-2511`, or fired
  on `.onAppear` at `:2490` for the picker-absorb-then-return case).
- **Animated property:** `absorptionPulseScale` (a `@State CGFloat`), feeding
  `.scaleEffect`.
- **Exact keyframes / timing:**
  1. `withAnimation(.easeOut(duration: 0.12)) { absorptionPulseScale = 1.08 }`
  2. After `DispatchQueue.main.asyncAfter(deadline: .now() + 0.12)`:
     `withAnimation(.spring(response: 0.35, dampingFraction: 0.55)) { absorptionPulseScale = 1.0 }`
  - Net: ease-out up to 1.08 over 0.12s, then a **bouncy** spring back to 1.0
    (low damping 0.55 → visible overshoot/settle).
- **CALayer equivalent:** `CAKeyframeAnimation` on `transform.scale` is the
  cleanest single-object form, but to preserve the exact two-phase feel use a
  sequence: a `CABasicAnimation` (scale → 1.08, 0.12s, `easeOut`) then a
  `CASpringAnimation` (scale → 1.0, response 0.35 / damping 0.55 → stiffness≈322,
  damping≈19.7, mass 1) scheduled 0.12s later, OR a
  `CAAnimationGroup` with `beginTime` offsets. Note the drop-target 1.03 factor
  (§5) **multiplies** this — port must compose both scale sources into one
  `transform.scale` value, not two competing transform animations.

## 5. Drop-target highlight (absorption target)

- **File/line:** `EventBlock.swift:2470-2496`, `2520`.
- **Trigger:** `isAbsorptionDropTarget` (a `.todo` being dragged over this event)
  → mirrored into `@State animatedDropTargetState` via `.onChange` at `:2492`.
- **Animated properties:**
  - Overlay appears: `RoundedRectangle(...).strokeBorder(Color.accentColor, lineWidth: 2.5)`.
  - Scale bump: the `(animatedDropTargetState ? 1.03 : 1.0)` factor in `:2482`.
- **Curve:** `withAnimation(.easeInOut(duration: 0.15)) { animatedDropTargetState = new }`.
- **CALayer equivalent:** a dedicated border sublayer (`borderWidth = 2.5`,
  `borderColor = accent`) whose `opacity` animates 0↔1 with `CABasicAnimation`
  (easeInEaseOut, 0.15s); concurrently a `transform.scale` `CABasicAnimation`
  to 1.03 (same curve/duration). Compose the 1.03 with the pulse scale (§4).

## 6. Boundary extension (timeline grows past midnight during drag/create)

- **File/line:** `TimelineView.swift:1529-1530` (the two `.animation` modifiers),
  `:1326-1340` (`boundaryExtensionAnimation`).
- **Trigger:** `value: boundaryExtensionHours.leading` / `.trailing` change — a
  move-drag or creation-drag approaches the top/bottom edge and the visible
  hour range extends.
- **Animated property:** the timeline content height / contained layout (extra
  leading/trailing hours), which re-flows everything below.
- **Curve:** `.interactiveSpring(response: 0.28, dampingFraction: 0.88, blendDuration: 0.12)`.
  Gated off entirely when **not** in an active move/creation drag, and when
  `accessibilityReduceMotion` is on → returns `nil` (snap, no animation). Gate
  logic in `calendarShouldAnimateTimelineBoundaryExtension(...)`.
- **CALayer equivalent:** `CASpringAnimation` (response 0.28 / damping 0.88 →
  stiffness≈503, damping≈39.5, mass 1, `blendDuration` has no CA analog — ignore
  or approximate with `fillMode`/additive). Animate the content layer's
  `bounds.size.height` and re-layout `position` of all event/now sublayers.
  Respect Reduce Motion: skip the animation, set values directly.
  **Plus a separate dismiss path** (`CalendarPageView.swift:2444-2448`): when the
  drag source clears near max pinch and the extension can't be scrolled away,
  after a 0.15s delay → `withAnimation(.easeOut(duration: 0.3))` collapse.

## 7. Pinch boundary visual scale resistance (rubber-band at min/max hour height)

- **File/line:** scale value `TimelineView.swift:1575-1581`; resistance progress
  curve `:591-612`; visual-scale curve `:706-716`; applied at `:1527`
  (`.scaleEffect(x: rangePinchVisualScale, y: rangePinchVisualScaleY, anchor: .center)`).
  Per-tick progress follow at `:1735-1739`.
- **Trigger:** during a `MagnificationGesture` the user keeps pinching **past**
  the min (fit) or max hour-height limit.
- **Animated property:** the timeline's vertical scale `rangePinchVisualScaleY`
  (x scale is always `1`, `:1571-1573`). This is the elastic give. Note: the
  *committed* hourHeight is clamped — only the visual scale stretches.
- **Resistance curve (exact):**
  - `rangePinchVisualScale` (X) = `1` always.
  - `rangePinchVisualScaleY` = `calendarPinchBoundaryVisualScale(step, progress, maxVisualDelta: 0.035)`:
    `eased = sin(progress · π/2)`; `delta = 0.035 · eased`; returns
    `step < 0 ? 1 + delta : 1 - delta` (push-bigger overscale up to +3.5%,
    push-smaller down to −3.5%).
  - `progress` = `calendarPinchBoundaryResistanceProgress(...)`: smoothstep
    `normalized²·(3 − 2·normalized)` of overshoot beyond `threshold 0.12`,
    saturating over `saturationOvershoot 0.28`.
  - Per-frame the displayed progress *follows* the target by a low-pass:
    `next = prev + (target − prev) · 0.35` (`rangePinchBoundaryFollowFactor`,
    `:1737`) — so the resistance ramps in/out smoothly, not instantly.
- **CALayer equivalent:** driven manually (gesture-coupled), **no implicit
  animation** — set `transform = CATransform3DMakeScale(1, scaleY, 1)` per
  `UIPinchGestureRecognizer` tick inside `setDisableActions(true)`. Reproduce
  the `sin`/smoothstep math + the 0.35 low-pass follow in code. Anchor = center
  (`layer.anchorPoint = (0.5, 0.5)`).

## 8. Pinch-end settle (hour-height commit + boundary release)

- **File/line:** `TimelineView.swift:1706-1733`.
- **Triggers/properties on gesture end:**
  - Frozen slot density released:
    `withAnimation(.easeInOut(duration: 0.3)) { rangePinchFrozenSlotMinutes = nil }`
    — this drives the **time-axis legend crossfade** (§11) via the `.id` flip.
  - `onHourHeightCommit?()` — persists the final hourHeight (the live stretch was
    already applied unanimated during the gesture; **no settle animation on the
    hour height itself** — it's committed in place).
  - Boundary overscale springs back: if `rangePinchBoundaryProgress != 0`,
    `withAnimation(.interactiveSpring(response: 0.22, dampingFraction: 0.78)) { rangePinchBoundaryProgress = 0 }`.
- **CALayer equivalent:** `CASpringAnimation` on `transform.scale.y` back to 1.0
  (response 0.22 / damping 0.78 → stiffness≈816, damping≈44.6, mass 1). The
  hourHeight commit itself is a direct, **unanimated** model write — do not add a
  CA animation there. Slot-density crossfade is §11.

## 9. Drag preview / creation preview (entry/exit)

- **File/line:** creation preview `TimelineView.swift:4360-4392`; cross-day drag
  preview `:4456-4490`; interrupt drag preview `:4494-4529`. Visibility gated by
  `dragState.draggingEventID != nil && currentMode == .move`
  (`:3991`) / by `creationPreviewByDay`.
- **Trigger:** drag/creation begins or ends (the preview view appears/disappears
  as the gating condition flips).
- **Animated property:** **no explicit transition** on these previews — they
  pop in/out with the conditional. Styling: fill `color.opacity(0.15)`, stroke
  `0.5`–`0.6` (creation stroke lineWidth 2, drag stroke 1), creation corner
  radius 10 (2 if zero-duration), drag preview `.shadow(radius: 8)`. The dragged
  source block goes `.opacity(... ? 0 : 1)` at `:3969` (hidden during move so
  only the preview shows).
- **CALayer equivalent:** a reusable preview sublayer toggled `isHidden` (or
  `opacity` 0/1) with **no animation** (matches current pop behavior). If you
  want to keep parity exactly: instant show/hide, `setDisableActions(true)`.
  Source-block hide = set its `opacity = 0` directly during move.

## 10. Interrupt parent compound-shape morph

- **File/line:** `EventBlock.swift:2626-2647` (compoundShape resolution),
  `:2976-3020` (shape application), shape type `CalendarInterruptParentCompoundShape`.
- **Trigger:** an interrupt becomes embedded in / detaches from a parent — the
  parent's outline morphs to a compound (notched) path; zIndex boost `+0.35`
  applies (§2).
- **Animated property:** the parent block's clip/stroke **path**. There is **no
  dedicated `.animation` on the path morph** in SwiftUI — the shape recomputes
  per layout; any motion comes from the slot spring (§1) repositioning, not a
  path interpolation. Treat as effectively non-animated path swap.
- **CALayer equivalent:** `CAShapeLayer` with `path`. To match current (no
  explicit morph), set `path` directly inside `setDisableActions(true)`. If a
  future slice wants it animated, `CABasicAnimation(keyPath: "path")` requires
  matching control-point counts — flag as a known divergence risk, not current
  behavior.

## 11. Time-axis legend crossfade on density change (freeze-at-start, crossfade-at-end)

- **File/line:** `TimelineView.swift:1550-1562` (`TimeAxisLabels` + `.id(effectiveSlotMinutes)`
  + `.transition(.opacity)`); freeze at `:1605` (`rangePinchFrozenSlotMinutes = slotMinutes`);
  release at `:1721-1723`.
- **Trigger:** the slot density (`slotMinutes`, e.g. 60↔30) changes when
  hourHeight crosses the ~76pt threshold. During the live pinch the density is
  **frozen** so the legend/grid don't flicker as hourHeight micro-oscillates.
  At gesture end the freeze releases.
- **Animated property:** identity of `TimeAxisLabels` via `.id(effectiveSlotMinutes)`.
  When the id flips, SwiftUI removes the old labels and inserts the new ones; the
  `.transition(.opacity)` makes the swap a crossfade.
- **Curve:** the `.id` flip happens inside
  `withAnimation(.easeInOut(duration: 0.3)) { rangePinchFrozenSlotMinutes = nil }`
  (`:1721`) — so the crossfade is **easeInOut 0.3s**. If density didn't change,
  slotMinutes is unchanged → no visible animation.
- **CALayer equivalent:** keep two label container sublayers (old + new). On
  density change, add new sublayer at `opacity 0`, run a paired `CABasicAnimation`
  on `opacity` (old → 0, new → 1), `easeInEaseOut`, 0.3s, then remove the old in
  the completion block. The **freeze** is pure model logic (don't recompute label
  layer contents while `frozenSlotMinutes != nil`).

## 12. Now-line + time legend periodic refresh

- **File/line:** now indicator `TimelineView.swift:4578-4604` (TimelineView
  `.periodic(from: .now, by: 1)`); time-axis labels + "current time" legend
  `:2531-2569`; live interrupt block `:4540-4573`.
- **Trigger:** `SwiftUI.TimelineView(.periodic(from: .now, by: 1))` — a **1-second**
  cadence tick. Each tick recomputes `now` and re-derives the y-offset of the
  red now-line, its dot, the "current time" legend text/position, and the live
  interrupt block's growing height.
- **Animated property:** none — it's a **discrete reposition every 1s** (no
  tween between ticks). Line is `Rectangle` 1.5pt tall + `Circle` 7pt dot at
  `indicatorColor.opacity(0.92)`, `.shadow(... radius 1.5 ...)`.
- **CALayer equivalent:** a `CADisplayLink` (or a 1s repeating `Timer`/`DispatchSourceTimer`)
  that recomputes y and sets `position` of the now-line/dot/legend sublayers
  **inside `setDisableActions(true)`** (no implicit 0.25s ease — the current
  behavior is an instant 1s-cadence jump). Note: a 1s `CADisplayLink` is wasteful;
  a 1s repeating timer matches the cadence. Existing `CADisplayLink` usage in this
  file (`:2822`, `:2906-2918`) is for **auto-scroll**, a different system.

## 13. Resize handle appearance + active-resize emphasis

- **File/line:** `EventBlock.swift:2778-2802`.
- **Triggers/properties:**
  - Handle visibility: `.opacity(showHandles ? 1 : 0)` (`:2800`) — `showHandles`
    requires drag-enabled + `renderedBlockHeight >= 32`.
  - Active-resize emphasis: handle capsule fill `color.opacity(isResizing ? 0.8 : 0.45·resizeHandleOpacity)`
    and width grows to `activeWidth` while resizing.
  - `.animation(.easeOut(duration: 0.2), value: isResizingTop)` and same for
    `isResizingBottom` (`:2801-2802`).
- **Curve:** easeOut 0.2s on the resize-active toggle.
- **CALayer equivalent:** handle sublayers; animate `opacity`/`bounds`/`backgroundColor`
  with `CABasicAnimation` (easeOut, 0.2s) keyed on resize start/stop.

## 14. Grace-resize handle fade-out (post-resize handle lingers then fades)

- **File/line:** `CalendarPageView.swift:1082-1083` (constants), `:1984-1994`
  (fade scheduling).
- **Trigger:** after a resize ends, handles linger for `resizeGraceDuration = 2.5s`,
  then fade over `resizeGraceFadeDuration = 0.35s` (fade starts at
  `2.5 − 0.35 = 2.15s`).
- **Animated property:** `resizeGraceState.handleOpacity` → 0.
- **Curve:** `withAnimation(.linear(duration: 0.35)) { handleOpacity = 0 }`.
- **CALayer equivalent:** schedule a delayed (2.15s) `CABasicAnimation` on the
  grace-handle sublayer `opacity` → 0, `.linear`, 0.35s, with a cancelable timer
  (mirror the `resizeGraceFadeTask?.cancel()` re-arm logic).

## 15. Absorb merge-target bubble (floating label above finger)

- **File/line:** `CalendarPageView.swift:3992-4024` (bubble body),
  `.transition(.opacity)` at `:4022`; the parent gate
  `.animation(.easeOut(duration: 0.2), value: hasAny)` at `:2381`.
- **Trigger:** during an absorb drag, `dragState.currentDropTargetEventID` +
  `currentTouchPointGlobal` non-nil → a capsule bubble naming the target event
  floats above the fingertip (clamped to screen; flips below near the top via
  `absorbBubbleCenter` `:4028`).
- **Animated property:** bubble presence → `.opacity` transition; its `.position`
  follows the finger per-frame (unanimated).
- **Curve:** opacity in/out driven by `.easeOut(duration: 0.2)` from the parent
  `hasAny` gate.
- **CALayer equivalent:** an overlay capsule sublayer; `opacity` 0↔1 via
  `CABasicAnimation` (easeOut, 0.2s) on appear/disappear; `position` set directly
  per touch tick inside `setDisableActions(true)`. Capsule uses
  `.ultraThinMaterial` → port needs a `UIVisualEffectView` (material is not a
  CALayer primitive).

## 16. Agentic analyzing shimmer + spinner + failed badge

- **File/line:** shimmer `EventBlock.swift:2692-2708`; spinner `:2805-2814`;
  failed-badge auto-hide `:2916-2937`.
- **Triggers/properties:**
  - **Shimmer:** while `isAgenticAnalyzing`, a static diagonal `LinearGradient`
    (white 0.05→0.22→0.05, topLeading→bottomTrailing) at
    `.opacity(isInDragState ? 0.08 : 0.18)`. **NOTE: this is currently a STATIC
    gradient — there is no traveling/animated shimmer modifier.** Do not add
    motion in the port; it's a fixed sheen.
  - **Spinner:** `ProgressView().progressViewStyle(.circular).controlSize(.small)`
    on `.ultraThinMaterial` Circle, top-trailing. Standard indeterminate spin.
  - **Failed badge:** on appear/`isAgenticFailed`, `isFailedBadgeVisible = true`,
    then after a 5s `Task.sleep`,
    `withAnimation(.easeOut(duration: 0.4)) { isFailedBadgeVisible = false }`
    (the "⚠️ " title prefix at `:2268` disappears).
- **CALayer equivalent:** shimmer = static `CAGradientLayer` (no animation).
  Spinner = host a `UIActivityIndicatorView` (don't reimplement spin in CA).
  Failed-badge fade = delayed (5s) `CABasicAnimation` on the badge sublayer
  `opacity` → 0, easeOut, 0.4s.

## 17. Range-mode morph (day ↔ 3-day/week ↔ month ↔ stream)

- **File/line:** `CalendarPageView.swift:1466`.
- **Trigger:** `value: calendarState.rangeMode` change — the whole timeline /
  month / list content swaps.
- **Animated property:** the content-region layout (the conditional swap between
  `timelineScroll`, month grid, `listContent`).
- **Curve:** `.animation(.spring(duration: 0.35, bounce: 0.15), value: rangeMode)`.
- **CALayer equivalent:** mostly above the timeline-layer boundary, but the
  timeline host view must tolerate being resized/replaced under a 0.35s bouncy
  spring. If the timeline itself is the CALayer port, expose a
  `setRangeMode(animated:)` that runs a `CASpringAnimation`
  (duration 0.35, bounce 0.15 → moderate overshoot; `CASpringAnimation` with
  `initialVelocity`/damping tuned to ~15% overshoot) on `bounds`/`opacity`.

## 18. "Jump to today" diagonal scroll spring

- **File/line:** `CalendarPageView.swift:3049-3070`.
- **Trigger:** user taps "today"; horizontal (day offset) + vertical (time scroll)
  animate together.
- **Curve:** `.spring(duration: 0.5, bounce: 0.06)` wrapping both
  `selectedDayOffset` and `verticalScrollPosition.scrollTo(...)`.
- **CALayer equivalent:** if scroll is a `UIScrollView`, use
  `setContentOffset` inside a `UIView.animate` spring or a manual `CADisplayLink`
  drive matching duration 0.5 / very low bounce 0.06 (near-critically-damped).

## 19. Day-paging / scroll-restore eases (horizontal)

- **File/line:** `TimelineView.swift:1795-1797`, `:1832-1834` (scroll-restore /
  snap-to-day, `.easeOut(duration: 0.2)`); `:1967-1969` (selected-day change,
  `.interactiveSpring(response: 0.36, dampingFraction: 0.9, blendDuration: 0.12)`,
  skipped under Reduce Motion → instant `scrollTo`).
- **Trigger:** day-slot snap on scroll end, programmatic day selection,
  `selectedDayOffset` change.
- **CALayer equivalent:** these drive a `ScrollViewReader.scrollTo`. In UIKit
  they map to `UIScrollView.setContentOffset(_:animated:)` or an explicit
  `UIView.animate`/`CASpringAnimation` on `contentOffset`. Reproduce both the
  0.2s easeOut (snap) and the 0.36/0.9 spring (selection), and the Reduce-Motion
  instant path.

## 20. Legend interaction settle + progressive day-cache fade-in

- **File/line:** legend settle `CalendarPageView.swift:2410-2417`
  (`.interactiveSpring(response: 0.24, dampingFraction: 0.9, blendDuration: 0.1)`
  when interaction ends, instant while interacting / under Reduce Motion);
  progressive cache fade `:3333-3336` & `:3372-3383` (`.easeIn(duration: 0.25)`
  as off-screen day occurrences populate the cache).
- **Trigger:** legend drag release (settle the continuous offset); a day's
  occurrences finishing loading into the cache (blocks fade in).
- **Animated property:** `legendCenteredOffsetContinuous` (spring); the inserted
  day's event sublayers `opacity` (easeIn 0.25s).
- **CALayer equivalent:** new day-column event sublayers added at `opacity 0`,
  `CABasicAnimation` opacity → 1, easeIn, 0.25s. Legend settle is parent-level.

---

## Curve → CALayer conversion cheat-sheet

| SwiftUI | duration / params | CALayer mapping |
|---|---|---|
| `.easeOut(0.12)` | pulse up | `CABasicAnimation`, `easeOut`, 0.12s |
| `.easeOut(0.15/0.2/0.25/0.3/0.4)` | various | `CABasicAnimation`, `easeOut` |
| `.easeInOut(0.15)` | drop-target, drag-state | `CABasicAnimation`, `easeInEaseOut`, 0.15s |
| `.easeInOut(0.3)` | legend crossfade | paired `opacity` `CABasicAnimation`, 0.3s |
| `.easeInOut(0.4)` | done-fade | `CABasicAnimation`, 0.4s |
| `.linear(0.35)` | grace-handle fade | `CABasicAnimation`, `linear`, 0.35s |
| `.spring(response:0.25, damping:0.85)` | overlap re-layout | `CASpringAnimation` stiffness≈632 damping≈42.7 mass 1 |
| `.spring(response:0.35, damping:0.55)` | pulse settle | `CASpringAnimation` stiffness≈322 damping≈19.7 mass 1 |
| `.interactiveSpring(0.28/0.88)` | boundary extension | `CASpringAnimation` stiffness≈503 damping≈39.5 |
| `.interactiveSpring(0.22/0.78)` | overscale release | `CASpringAnimation` stiffness≈816 damping≈44.6 |
| `.interactiveSpring(0.36/0.9)` | day-select scroll | `CASpringAnimation` / scroll contentOffset spring |
| `.interactiveSpring(0.24/0.9)` | legend settle | `CASpringAnimation` |
| `.spring(duration:0.35, bounce:0.15)` | range-mode | `CASpringAnimation` ~15% overshoot |
| `.spring(duration:0.5, bounce:0.06)` | jump-to-today | near-critically-damped contentOffset spring |

Spring conversion (SwiftUI `response`/`dampingFraction` → CASpringAnimation):
`stiffness = (2π / response)²`, `damping = (4π · dampingFraction) / response`,
`mass = 1`. Use `animation.duration = animation.settlingDuration` so the layer
holds the final value. `blendDuration` has no CA analog (ignore).

---

## Reduce Motion

Honored at: boundary extension (`:1335`), day-select scroll (`:1964`), range-mode
banner (`CalendarPageView.swift:1438`), legend settle (`:2409`), in-event auto-resume
(`CalendarEventDetailView.swift:3170`). The CALayer port must check
`UIAccessibility.isReduceMotionEnabled` and substitute an instant value set
(`setDisableActions(true)`) for these.

---

## Adjacent / out of scope (separate widget, not the canvas timeline)

These live in `CalendarEventDetailView.swift` and animate the **in-event detail
timeline scrubber**, not the canvas — listed so the rewrite doesn't conflate them:
- Auto-resume ease `:3170` (`calendarEventTimelineAutoResumeAnimationDuration = 0.24`).
- Composer ease `:3192` (`calendarEventTimelineComposerAnimationDuration = 0.18`).
- Nearby-note highlight `.easeInOut(0.15)` `:1392, :2358, :2613, :2754`.
- Note/marker transitions `:2547-2567`.

---

## Summary of distinct animations

20 distinct canvas-timeline animation surfaces (§1–§20). The static-gradient
shimmer (§16) and the no-op `calendarEventBlockScale` (§3) are explicitly NOT
animations and must NOT gain motion in the port.
