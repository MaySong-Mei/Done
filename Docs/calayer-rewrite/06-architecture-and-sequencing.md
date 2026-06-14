# CALayer Timeline Rewrite — Architecture & Sequencing

Derived from parity specs 01–05. Hard requirement: **zero behavior change** vs the current SwiftUI timeline. Every slice is verified against the specs before the next begins.

## Core principles

1. **Flag-gated parallel path.** The SwiftUI timeline stays fully intact. The UIKit+CALayer path lives behind a runtime flag so we can A/B the two side by side, diff for parity, and roll back instantly. SwiftUI path is removed only after parity sign-off.
2. **Reuse pure logic, rewrite only rendering.** Overlap topology, `yOffset`, hourHeight functions, occurrence filtering, pinch math, boundary-extension math are all pure functions (specs 03). The CALayer view is a **new consumer** of them — not a reimplementation. The hardest algorithm (overlap topology, spec 03 §clustering) is NOT touched.
2b. **All three rangeModes in scope.** day / 3-day / week (1 / 3 / 7 columns of the same `CalendarDayLayerView`). Multi-column modes must reach parity on per-mode column width AND cross-column drag (a block dragged from one column landing in another). Only month/year views are deferred.
3. **Parity-first, optimize-later.** First milestone = full per-event CALayer subtree (independent animation + full fidelity). LoD (cheap bulk + rich foreground) and viewport virtualization come as *later* milestones, because they risk subtle visual drift and parity is the hard gate.
4. **Preserve no-ops exactly.** `calendarEventBlockScale` stays a constant 1.0; text "fade" stays structural width/height gates, not alpha; agentic shimmer stays a static gradient. The rewrite ports behavior, not "fixes."

## Boundary placement

Keep the SwiftUI shell: `CalendarPageView`, the `ScrollView`/pager, and `PinchScrollCoordinator` (already UIKit). Replace only the **per-day event + grid rendering** (today: `ForEach(EventBlock)` + grid Canvas) with one persistent `UIView` per day column that owns a CALayer tree.

```
CalendarPageView (SwiftUI, unchanged)
└─ TimelinePagerView (SwiftUI ScrollView + pager, unchanged)
   └─ PinchScrollCoordinator (existing UIKit, unchanged)
   └─ per day offset:
      └─ CalendarDayLayerView  ← NEW UIViewRepresentable boundary
         └─ DayLayerHostView : UIView   (persistent — solves coordinator-survives-rebuild, spec 02 G-79..81)
            ├─ gridLayer / nowLineLayer / futureZoneLayer
            ├─ eventLayer pool: per-occurrence CALayer subtree
            │   └─ bg(CAShapeLayer) · border · todoBorder · shadow · hatch · agentic · triangle · handles · CATextLayer
            └─ native UIGestureRecognizers (move/resize/create/pinch-suppression/absorption)
```

Why per-day UIView (not per-event UIViewRepresentable like today): a persistent day view means gesture state is plain UIKit state that survives content rebuilds natively, and there is one mask/transaction owner per day.

## State bridging (spec 05 contract)

- **Inputs** (~30): injected via `updateUIView` — occurrences (pull via `occurrencesForOffset`), hourHeight, focus/preview/grace props, the shared `EventDragState`. One-way except the 3 `@Binding`s (hourHeight, selectedDayOffset, rangeMode).
- **Outputs** (13 callbacks): fire the SAME closures the SwiftUI path uses (`onEventDragEnded`, `onEventResizeEnded`, `onCreateEvent`, focus entry, absorption commit …). EventStore mutations unchanged — still routed through `applyRecurringEdit` + sync guards.
- **CRITICAL:** live drag stays in plain UIKit state. Only the *coarse* fields (`draggingEventID`, `currentDropTargetEventID`) mirror back into the SwiftUI-observed `EventDragState`. Never mirror per-frame `dragOffset` into `@Published` (spec 05 trickiest risk).

## Slice sequence (each flag-gated, each parity-verified)

| Slice | Scope | Verifies against | Parallelizable? |
|---|---|---|---|
| **S0** | Scaffold: flag, `CalendarDayLayerView` + `DayLayerHostView`, static event render (bg+border+text) at fixed hourHeight, consuming existing layout/overlap funcs. No gestures. | static visual A/B | foundation — must be first, single owner |
| **S1** | Full event visual fidelity: todo border, shadow, hatch, agentic, triangle, resize-handle visuals, compound interrupt cutout, stack-peek, opacity states, structural text gates. | spec 01 (16 items) | ∥ with S2 |
| **S2** | Grid + now-line + future-zone tint + legend crossfade. | spec 03 grid, spec 04 §11 | ∥ with S1 |
| **S3** | Pinch repaint: hourHeight → layer frame updates in `CATransaction{disableActions}`. **THE perf milestone — re-run benchmark here.** Reuse existing PinchScrollCoordinator. | spec 03 pinch, benchmark | after S0 |
| **S4** | Gestures: move/resize/create/edge-auto-scroll/paging/absorption → native UIKit recognizers on the day view. | spec 02 (85 items) | after S0, large |
| **S5** | Animations: all 20 via CATransaction/CASpringAnimation/CAKeyframe. | spec 04 (20 items) | after S1+S4 |
| **S6** | Optimize: viewport virtualization (sub-day culling) + layer pool. **Data-growth win — re-run benchmark at high N.** | benchmark, no visual change | after parity holds |
| **S7** | Parity sign-off, flip flag default, decide SwiftUI-path removal. | full spec checklist | last |

## Verification harness

- Existing `TimelineRenderBenchmarkTests` = perf regression baseline (re-run at S3, S6).
- Parity checklist = the spec items (16 visual + 85 gesture + layout + 20 animation) as a literal pass/fail list.
- Manual A/B via the flag: same data, toggle renderer, compare.

## Highest-risk ports (from squad)

1. Compound interrupt geometry — per-vertex radius clamping in `calendarRoundedClosedPolygonPath` (spec 01 §16).
2. Hit-test fall-through inset mirrored on both hit area + contentShape (spec 02 G-3/4/5).
3. Auto-scroll compensation accumulation + same-scrollview special case (spec 02 G-18/39).
4. Pinch hourHeight + scrollY co-commit in one transaction (spec 02 G-75 / spec 03).
5. Absorption pulse × drop-target scale must compose into one `transform.scale` (spec 04 §4/§5).
