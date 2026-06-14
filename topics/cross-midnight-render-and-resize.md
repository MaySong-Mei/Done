# 【bug】Cross-midnight events mis-render in Day view + drag-resize doesn't follow the finger

cc @MaySong-Mei

## Background

- Day view runs on the CALayer renderer (`CalendarDayLayerView`, `AppSettingsKeys.useCALayerTimeline` ON by default). Env: iPhone 17 Pro / iOS 26.5.
- Four defects, all observed on events whose **end time crosses 00:00** (ends on the next day), plus the resize-drag path that handles them:
  1. **Drag-resize doesn't grow live.** Long-press an event (e.g. 22:00–00:00), grab the bottom handle and drag down past midnight: the block does NOT follow the finger during the drag; it only snaps to the new size **after release** (e.g. ends up 22:00–01:15).
  2. **Cross-midnight block sometimes doesn't render at all** — the block disappears in some states.
  3. **Cross-midnight block renders far too tall** — a block that should end around 00:00 is drawn extending well past the 01:00 line, covering empty space and other rows.
  4. **Cross-midnight block overlaps neighbors** — instead of column-splitting against a same-time event (e.g. a 19:30–22:00 event), the cross-midnight block is drawn on top of / overlapping it.

## Discussion Summary

Root cause traced in code (no fix applied yet):

- **No midnight split.** A cross-midnight event is a single occurrence carried on its start day with its *full* range (end on the next day). The renderer does not split it into a `start→24:00` segment on day N and a `00:00→end` segment on day N+1.
- **Static render clips to `visibleEnd`, which is PAST midnight.**
  `CalendarDayLayerView.verticalFrame(...)` (`CalendarDayLayerView.swift:1770-1799`) computes height from `clippedEnd = min(occurrence.range.end, visibleEnd)`.
  `visibleEnd = calendarTimelineVisibleEnd(...)` = `dayStart + (calendarTimelineBaseVisibleHours + trailingExtendedHours) hours` (`TimelineEditMapping.swift:97-106`), and `calendarTimelineBaseVisibleHours = 24` (`TimelineEditMapping.swift:10`). With any `trailingExtendedHours > 0`, `visibleEnd` is *after* next-day 00:00, so a cross-midnight block legitimately extends below the 24:00 line into the trailing zone — its height is the full duration up to `visibleEnd`, not clamped to the day.
- **Live resize clamps to `dayEnd` (exactly midnight) — inconsistent with the above.**
  `liveAdjustedOccurrence(...)` resize branch (`CalendarDayLayerView.swift:1851-1863`) does `clippedEnd = min(preview.end, dayEnd)` where `dayEnd = startOfDay(model.date) + 1 day`. So during a resize drag the previewed end can never pass midnight, while the *committed* render (verticalFrame) happily draws past midnight. That mismatch is the live-resize bug (1): dragging the bottom edge below the 24:00 line does nothing until release, then the committed range jumps to its full past-midnight size.
- Bugs (2)/(3)/(4) all flow from the same unsplit + unclamped-to-day geometry feeding `verticalFrame` and then `CalendarLayout.overlapLayout`: an over-tall / out-of-day frame can (3) overshoot the day, (4) poison the overlap column assignment so it covers neighbors, and (2) fall outside the cull/visible test in some scroll states so it's dropped entirely. The committed per-day range is built via `calendarAdjustedOccurrenceRange(...)` (`TimelineView.swift:769`), which only honors the day-clamp for `.move` — the resize/static path doesn't get the same clamping.

## Decisions

(Proposed — for @MaySong-Mei to confirm.)

- Make the day-boundary handling **consistent**: either (a) split a cross-midnight occurrence into per-day segments (`start→24:00` on the start day, `00:00→end` on the next day), or (b) clamp BOTH the static `verticalFrame` and the live `liveAdjustedOccurrence` to the same `dayEnd` so a block never renders below its own day.
- Whichever is chosen, `verticalFrame` and `liveAdjustedOccurrence` (resize) must use the **same** day-end value so live drag and committed render agree.

## In Scope

- Cross-midnight occurrence geometry in `CalendarDayLayerView.verticalFrame` and the resize branch of `liveAdjustedOccurrence`.
- Overlap layout input for cross-midnight occurrences.
- Live-resize preview tracking past the day boundary.

## Out of Scope

- The SwiftUI legacy renderer (kept behind the toggle).
- Recent resize-handle grow animation and the event-detail mini-timeline changes — those only touch the handle `CAShapeLayer` path and the detail mini-timeline height, not the main renderer's frame / overlap / live-drag.

## Execution Notes

- Not implemented yet — handed off. Code is at a clean, building state; no main-renderer logic was changed for this report.
- Suggested regression tests:
  - Day view, occurrence start 22:00 / end 01:00 next day: assert the rendered frame is clamped to the day (or split), and its bottom does not exceed the day column bottom.
  - During an active resize session, assert the dragged block's frame height tracks the live-adjusted range using the SAME day-end clamp as the static render (no freeze at midnight, no jump on release).

## Impact on Understanding

- The core issue is that the CALayer Day renderer treats cross-midnight events inconsistently: the committed/static path lets them extend past midnight (via `visibleEnd`), while the live-resize path clamps them at midnight (`dayEnd`). Unifying the day-boundary model (split, or one shared clamp) should resolve all four symptoms.
