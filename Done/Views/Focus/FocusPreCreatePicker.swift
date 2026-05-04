import SwiftUI

/// Interactive mini-calendar surface for the focus pre-create flow.
/// Renders surrounding events as ghost blocks, the now-line, and the
/// proposed slot as a draggable colored block with edge handles. The
/// user picks the time by manipulating the slot itself, not by tapping
/// adjusters — same hand-feel as the calendar canvas, scoped to the
/// "into the event" entry ceremony.
///
/// Coordinate system mirrors `FocusEventFlowView`: `now` is anchored at
/// `h * 0.5`, with `pps = h / (visibleHours * 3600)` controlling vertical
/// density. Past is up, future is down.
///
/// Constraints enforced live during drag (snap-to-15min):
///   - start ≤ snapped(now)              (now must be inside)
///   - end ≥ snapped(now) + 15min        (now must be inside, with runway)
///   - end ≥ start + 15min               (minimum duration)
struct FocusPreCreatePicker: View {
    @Binding var startDate: Date
    @Binding var endDate: Date
    let now: Date
    let allOccurrences: [CalendarLayout.EventOccurrence]
    let typeColor: Color
    /// What the slot block displays as its title — typically the
    /// user's typed name or the template's type name as fallback.
    /// Lets the slot read as a real calendar event block.
    let slotTitle: String

    /// Default visible window when the slot is small. The calendar's
    /// own half-hour grid kicks in at hourHeight ≥ 76
    /// (`calendarLegendSlotMinutes`), so 4h × ~320pt picker height
    /// keeps us in the same regime as the calendar.
    private let baseVisibleHours: CGFloat = 4
    /// Hard ceiling so an extreme drag doesn't zoom out into a useless
    /// hairline view. A 24h window (now ±12h) covers a slot at the
    /// 12h-duration limit with breathing room.
    private let maxVisibleHours: CGFloat = 24

    /// Auto-fit: where `now` sits vertically and how many hours the
    /// timeline shows. Two-stage response to the slot growing:
    ///   1. **Auto-scroll** — slide the `now`-anchor up or down (out
    ///      of the geometric center) so the slot stays visually
    ///      centered without zooming. Cheap, no scale change.
    ///   2. **Auto-pinch** — only when the slot is too long to fit at
    ///      all even with `now` off-center, expand `visibleHours` so
    ///      the whole slot still fits. More expensive (every other
    ///      element rescales), so we'd rather not.
    /// Symmetrical small slots stay perfectly centered (`nowYRatio =
    /// 0.5`) at base zoom; asymmetric drags shift the anchor instead
    /// of triggering an unnecessary zoom-out.
    private struct AutoFit: Equatable {
        let visibleHours: CGFloat
        let nowYRatio: CGFloat
    }

    private var autoFit: AutoFit {
        let pastReachH = max(0, now.timeIntervalSince(startDate)) / 3600
        let futureReachH = max(0, endDate.timeIntervalSince(now)) / 3600
        let padding: Double = 0.5  // 30min margin above start / below end

        // Required window is just slot duration + padding (NOT
        // 2×max(reach) + 1 — that's what forced premature pinching
        // before). Now reads at any vertical position, not just centre.
        let neededHours = CGFloat(pastReachH + futureReachH + 2 * padding)
        let visibleHours = min(maxVisibleHours, max(baseVisibleHours, neededHours))

        // Place `now` so the slot's mid-point lands at the picker's
        // mid-point — that's the auto-scroll. Symmetric → 0.5;
        // future-heavy → near top; past-heavy → near bottom.
        let asymmetry = CGFloat(futureReachH - pastReachH) / visibleHours
        let unclamped = 0.5 - 0.5 * asymmetry

        // Clamp so the slot edges stay inside the picker with `padding`
        // hours of margin. When the slot fully fits, this is a no-op;
        // when it'd otherwise blow past an edge, the clamp keeps it in.
        let minRatio = CGFloat(pastReachH + padding) / visibleHours
        let maxRatio = 1 - CGFloat(futureReachH + padding) / visibleHours
        let nowYRatio: CGFloat
        if minRatio <= maxRatio {
            nowYRatio = min(max(unclamped, minRatio), maxRatio)
        } else {
            // Defensive: max-window can't accommodate slot + padding.
            // Falls outside our 12h slot / 24h window contract but
            // keeps behaviour graceful if the constants ever change.
            nowYRatio = unclamped
        }
        return AutoFit(visibleHours: visibleHours, nowYRatio: nowYRatio)
    }

    /// Gutter where hour labels render — matches TimelineView.swift
    /// (`labelWidth = 26`) so the picker reads as a slice of the same
    /// calendar.
    private let labelWidth: CGFloat = 26
    /// Horizontal inset between the gutter and the event blocks —
    /// matches TimelineView's single-day `eventHorizontalInset = 8`.
    private let eventInset: CGFloat = 8
    /// Outside-the-slot tap zone so handles stay reachable on short
    /// (15-30 min) slots where the visible block is only ~15-30pt tall.
    private let handleHitHeight: CGFloat = 26
    /// Snap quantum — keeps the picker aligned with the rest of the
    /// app's 15-minute grid (calendar drag-to-create, focus ±15 actions).
    private static let snapStep: TimeInterval = 15 * 60
    private static let minimumDuration: TimeInterval = 15 * 60
    /// Hard ceiling on slot length. A focus session can't usefully span
    /// more than half a day, and capping here keeps the auto-pinched
    /// window bounded.
    private static let maximumDuration: TimeInterval = 12 * 3600

    /// Initial start/end captured at the beginning of a drag so deltas
    /// apply against the gesture origin, not the live (already-mutated)
    /// state. Cleared on drag end so a new gesture re-snapshots.
    @State private var dragInitialStart: Date?
    @State private var dragInitialEnd: Date?

    private let calendar = Calendar.current

    /// Snapshot of the layout values used by every layer in the ZStack.
    /// Computed once per body invocation in the GeometryReader closure
    /// so each layer doesn't have to re-derive it.
    private struct Geometry {
        let h: CGFloat
        let w: CGFloat
        let nowY: CGFloat
        let pps: CGFloat
        let eventLeft: CGFloat
        let eventW: CGFloat
        let areaW: CGFloat
        let slotTop: CGFloat
        let slotH: CGFloat
        let slotBottom: CGFloat
        let windowStart: Date
        let windowEnd: Date
    }

    private func makeGeometry(_ size: CGSize) -> Geometry {
        let h = size.height
        let w = size.width
        let fit = autoFit
        let nowY = h * fit.nowYRatio
        let pps = h / (fit.visibleHours * 3600)
        // Window edges are derived from where `now` actually sits, not
        // just visibleHours/2. With auto-scroll, those two diverge.
        let secondsAbove = Double(nowY) / Double(pps)
        let secondsBelow = Double(h - nowY) / Double(pps)
        let windowStart = now.addingTimeInterval(-secondsAbove)
        let windowEnd = now.addingTimeInterval(secondsBelow)
        let eventLeft = labelWidth
        let eventW = w - eventLeft
        let areaW = eventW - eventInset * 2
        let slotTop = nowY + CGFloat(startDate.timeIntervalSince(now)) * pps
        let slotH = max(0, CGFloat(endDate.timeIntervalSince(startDate)) * pps)
        return Geometry(
            h: h, w: w, nowY: nowY, pps: pps,
            eventLeft: eventLeft, eventW: eventW, areaW: areaW,
            slotTop: slotTop, slotH: slotH, slotBottom: slotTop + slotH,
            windowStart: windowStart, windowEnd: windowEnd
        )
    }

    var body: some View {
        GeometryReader { geo in
            let g = makeGeometry(geo.size)
            ZStack(alignment: .topLeading) {
                backgroundLayer(g)
                ghostsLayer(g)
                nowLayer(g)
                slotLayer(g)
                handlesLayer(g)
            }
        }
        // Soft fade at top + bottom edges replaces the hard
        // `.clipped()` cut. Ghost blocks and the slot bleed off into
        // the surrounding focus surface instead of meeting a sharp
        // edge against the meta block above and the action row below.
        // ~14pt fade on each side is enough for the eye to read
        // "continues beyond" without visibly hiding content the user
        // cares about.
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.05),
                    .init(color: .black, location: 0.95),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        // Animate the auto-fit (zoom + scroll) so the canvas glides
        // when bindings change rather than snapping. During a drag,
        // bindings change every frame, so the picker "follows along"
        // visually; the easing just smooths out the per-frame steps.
        .animation(.easeInOut(duration: 0.18), value: autoFit)
    }

    // MARK: - Layers

    @ViewBuilder
    private func backgroundLayer(_ g: Geometry) -> some View {
        let nowMinutes = calendar.component(.hour, from: now) * 60
            + calendar.component(.minute, from: now)
        ForEach(hourMarkers(from: g.windowStart, to: g.windowEnd), id: \.self) { hour in
            let y = g.nowY + CGFloat(hour.timeIntervalSince(now)) * g.pps
            let halfY = y + 1800 * g.pps
            let hourMinutes = calendar.component(.hour, from: hour) * 60
            let isMidnight = calendar.component(.hour, from: hour) == 0
            ZStack(alignment: .topLeading) {
                // Hour grid line — matches TimelineView
                // (.secondary.opacity(0.15), 1pt).
                Rectangle()
                    .fill(Color.secondary.opacity(0.15))
                    .frame(width: g.areaW, height: 1)
                    .offset(x: g.eventLeft + eventInset, y: y)

                // Half-hour grid line — TimelineView renders these as
                // dashed at 1.5pt when zoomed in (hourHeight ≥ 76).
                // SwiftUI shapes don't dash a Rectangle directly;
                // `Path { … }.stroke(style: dash)` is the easiest way
                // to keep the dashed look without dropping to Canvas.
                Path { p in
                    p.move(to: CGPoint(x: 0, y: 0))
                    p.addLine(to: CGPoint(x: g.areaW, y: 0))
                }
                .stroke(
                    Color.secondary.opacity(0.15),
                    style: StrokeStyle(lineWidth: 1, dash: [3, 4])
                )
                .frame(width: g.areaW, height: 1)
                .offset(x: g.eventLeft + eventInset, y: halfY)

                // Hour label — matches TimelineView (size 9, semibold,
                // .secondary.opacity(0.6), trailing-aligned in the
                // gutter, ~2pt above the grid line). fixedSize +
                // minimumScaleFactor mirror TimelineView so labels
                // never truncate or wrap inside the gutter.
                if abs(hourMinutes - nowMinutes) > 15 {
                    Text(formatHour(hour))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.secondary.opacity(0.6))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(width: labelWidth - 2, alignment: .trailing)
                        .offset(x: 0, y: y - 8)
                }

                // Date hint at midnight crossings — small relative-day
                // pill ("Yesterday" / "Today" / "Tomorrow") sitting
                // inline with the gridline in the event area, so the
                // user can tell which day a far-out hour belongs to.
                if isMidnight {
                    Text(relativeDayName(for: hour))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill(Color.secondary.opacity(0.12))
                        )
                        .offset(x: g.eventLeft + eventInset + 6, y: y - 10)
                }
            }
        }
    }

    /// "Yesterday" / "Today" / "Tomorrow" relative to `now`. Falls
    /// back to a short "MMM d" date label for anything outside that
    /// 3-day window — at the 24h max-zoom we won't actually see those,
    /// but the fallback keeps the helper safe.
    private func relativeDayName(for date: Date) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) { return "Yesterday" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(date, inSameDayAs: tomorrow) { return "Tomorrow" }
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f.string(from: date)
    }

    @ViewBuilder
    private func ghostsLayer(_ g: Geometry) -> some View {
        ForEach(allOccurrences, id: \.id) { occ in
            ghostBlock(for: occ, geometry: g)
        }
    }

    @ViewBuilder
    private func ghostBlock(
        for occ: CalendarLayout.EventOccurrence,
        geometry g: Geometry
    ) -> some View {
        // Match TimelineView event blocks (corner 10, fill 0.15,
        // stroke 0.5 at 1pt) but render WITHOUT titles — neighboring
        // events are background context here, not protagonists; their
        // names would compete with the slot the user is naming.
        let color = CalendarLayout.eventColor(for: occ.event)
        let blockTop = g.nowY + CGFloat(occ.range.start.timeIntervalSince(now)) * g.pps
        let blockH = CGFloat(occ.range.end.timeIntervalSince(occ.range.start)) * g.pps
        let blockBottom = blockTop + blockH
        if blockBottom > -20 && blockTop < g.h + 20 {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(color.opacity(0.15))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(color.opacity(0.5), lineWidth: 1)
                )
                .frame(width: max(0, g.areaW), height: max(0, blockH - 2))
                .offset(x: g.eventLeft + eventInset, y: blockTop + 1)
        }
    }

    @ViewBuilder
    private func nowLayer(_ g: Geometry) -> some View {
        // Match TimelineView's now-indicator (line 4122–4148): 1.5pt
        // line at 0.92 opacity, 7pt dot, both with a faint shadow so
        // they lift slightly off the grid; gutter legend label uses
        // the same shadow treatment.
        let indicatorColor = Color.primary
        let dotSize: CGFloat = 7
        let lineHeight: CGFloat = 1.5
        ZStack(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(indicatorColor.opacity(0.92))
                    .frame(width: g.eventW - eventInset, height: lineHeight)
                    .offset(x: g.eventLeft + eventInset, y: g.nowY - lineHeight / 2)
                Circle()
                    .fill(indicatorColor)
                    .frame(width: dotSize, height: dotSize)
                    .offset(x: g.eventLeft + eventInset - dotSize / 2, y: g.nowY - dotSize / 2)
            }
            .shadow(color: Color.black.opacity(0.18), radius: 1.5, x: 0, y: 0.5)

            Text(formatTime(now))
                .font(.system(size: 9, weight: .bold).monospacedDigit())
                .foregroundStyle(indicatorColor)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .fixedSize(horizontal: true, vertical: false)
                .frame(width: labelWidth - 2, alignment: .trailing)
                .offset(x: 0, y: g.nowY - 6)
                .shadow(color: Color.black.opacity(0.18), radius: 1, x: 0, y: 0.5)
        }
    }

    @ViewBuilder
    private func slotLayer(_ g: Geometry) -> some View {
        // Identical content layout to a calendar event block (see
        // TimelineView.swift:3994–4011): corner 10, fill 0.15 + 0.5
        // stroke at 1pt, with a leading-aligned VStack of title (12pt
        // semibold) + time (9pt medium monospaced .secondary) inside
        // 8pt padding. The slot reads as a real event block — same
        // typography, same paddings, same corners — just with a
        // brighter stroke so the active one is clear.
        let blockShape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        blockShape
            .fill(typeColor.opacity(0.15))
            .overlay(blockShape.stroke(typeColor, lineWidth: 1.25))
            .overlay(alignment: .topLeading) {
                slotContent(slotH: g.slotH)
                    .padding(8)
            }
            .frame(width: max(0, g.areaW), height: g.slotH)
            .offset(x: g.eventLeft + eventInset, y: g.slotTop)
            .gesture(bodyDrag(pps: g.pps))
    }

    @ViewBuilder
    private func slotContent(slotH: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if slotH >= 24 {
                Text(slotTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            if slotH >= 40 {
                Text("\(formatTime(startDate)) – \(formatTime(endDate))")
                    .font(.system(size: 9, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private func handlesLayer(_ g: Geometry) -> some View {
        // Edge-resize handles: short type-colored bars centered on each
        // slot edge — reads as a grip the way iOS sheet-grabbers and
        // editing handles do. Hit zones extend ~26pt outside the slot
        // so even very short slots are draggable.
        let barWidth: CGFloat = 28
        let barHeight: CGFloat = 3
        ZStack(alignment: .topLeading) {
            Capsule()
                .fill(typeColor)
                .frame(width: barWidth, height: barHeight)
                .offset(
                    x: g.eventLeft + eventInset + (g.areaW - barWidth) / 2,
                    y: g.slotTop - barHeight / 2
                )
            Rectangle()
                .fill(Color.clear)
                .contentShape(Rectangle())
                .frame(width: max(0, g.areaW), height: handleHitHeight)
                .offset(x: g.eventLeft + eventInset, y: g.slotTop - handleHitHeight / 2)
                .gesture(startEdgeDrag(pps: g.pps))

            Capsule()
                .fill(typeColor)
                .frame(width: barWidth, height: barHeight)
                .offset(
                    x: g.eventLeft + eventInset + (g.areaW - barWidth) / 2,
                    y: g.slotBottom - barHeight / 2
                )
            Rectangle()
                .fill(Color.clear)
                .contentShape(Rectangle())
                .frame(width: max(0, g.areaW), height: handleHitHeight)
                .offset(x: g.eventLeft + eventInset, y: g.slotBottom - handleHitHeight / 2)
                .gesture(endEdgeDrag(pps: g.pps))
        }
    }

    // MARK: - Drag gestures

    private func bodyDrag(pps: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                if dragInitialStart == nil {
                    dragInitialStart = startDate
                    dragInitialEnd = endDate
                }
                guard let initStart = dragInitialStart,
                      let initEnd = dragInitialEnd else { return }
                let snapped = snappedDelta(from: value.translation.height, pps: pps)
                applyBodyDelta(snapped, initStart: initStart, initEnd: initEnd)
            }
            .onEnded { _ in
                dragInitialStart = nil
                dragInitialEnd = nil
            }
    }

    private func startEdgeDrag(pps: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                if dragInitialStart == nil {
                    dragInitialStart = startDate
                }
                guard let initStart = dragInitialStart else { return }
                // 2× sensitivity (`pps / 2`): in the non-pinch regime
                // the auto-scroll moves `nowY` by half the finger's
                // displacement in the OPPOSITE direction, so the slot
                // edge's own slope is `pps / 2`. Doubling the conversion
                // here cancels that out — finger moves N pt → slot
                // edge moves N pt. In the pinch regime sensitivity
                // would ideally grow further, but that's the asymptote
                // case where the user is pulling toward the picker
                // edge anyway.
                let snapped = snappedDelta(from: value.translation.height, pps: pps / 2)
                applyStartDelta(snapped, initStart: initStart)
            }
            .onEnded { _ in
                dragInitialStart = nil
            }
    }

    private func endEdgeDrag(pps: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                if dragInitialEnd == nil {
                    dragInitialEnd = endDate
                }
                guard let initEnd = dragInitialEnd else { return }
                // 2× sensitivity — see `startEdgeDrag` for the math.
                let snapped = snappedDelta(from: value.translation.height, pps: pps / 2)
                applyEndDelta(snapped, initEnd: initEnd)
            }
            .onEnded { _ in
                dragInitialEnd = nil
            }
    }

    /// Convert a Y-axis pixel translation into a snapped time delta.
    /// Positive translation (downward drag) → positive seconds (later).
    private func snappedDelta(from translation: CGFloat, pps: CGFloat) -> TimeInterval {
        guard pps > 0 else { return 0 }
        let raw = TimeInterval(translation / pps)
        return (raw / Self.snapStep).rounded() * Self.snapStep
    }

    // MARK: - Constraint application

    private func applyBodyDelta(_ delta: TimeInterval, initStart: Date, initEnd: Date) {
        let snappedNow = calendarSnapDateToMinuteGrid(now)
        var newStart = initStart.addingTimeInterval(delta)
        var newEnd = initEnd.addingTimeInterval(delta)

        if newStart > snappedNow {
            let clamp = snappedNow.timeIntervalSince(initStart)
            newStart = initStart.addingTimeInterval(clamp)
            newEnd = initEnd.addingTimeInterval(clamp)
        }
        let lowerEnd = snappedNow.addingTimeInterval(Self.minimumDuration)
        if newEnd < lowerEnd {
            let clamp = lowerEnd.timeIntervalSince(initEnd)
            newStart = initStart.addingTimeInterval(clamp)
            newEnd = initEnd.addingTimeInterval(clamp)
        }
        startDate = newStart
        endDate = newEnd
    }

    private func applyStartDelta(_ delta: TimeInterval, initStart: Date) {
        let snappedNow = calendarSnapDateToMinuteGrid(now)
        let candidate = initStart.addingTimeInterval(delta)
        let upperBound = min(
            snappedNow,
            endDate.addingTimeInterval(-Self.minimumDuration)
        )
        // Lower bound: start can't go below end - 12h (so duration
        // stays ≤ 12h). Combined with the upper bound this clamps both
        // sides of the start edge.
        let lowerBound = endDate.addingTimeInterval(-Self.maximumDuration)
        startDate = max(min(candidate, upperBound), lowerBound)
    }

    private func applyEndDelta(_ delta: TimeInterval, initEnd: Date) {
        let snappedNow = calendarSnapDateToMinuteGrid(now)
        let candidate = initEnd.addingTimeInterval(delta)
        let lowerBound = max(
            startDate.addingTimeInterval(Self.minimumDuration),
            snappedNow.addingTimeInterval(Self.minimumDuration)
        )
        // Upper bound: end can't exceed start + 12h.
        let upperBound = startDate.addingTimeInterval(Self.maximumDuration)
        endDate = min(max(candidate, lowerBound), upperBound)
    }

    // MARK: - Formatters

    private func hourMarkers(from start: Date, to end: Date) -> [Date] {
        var markers: [Date] = []
        var hour = calendar.nextDate(
            after: start.addingTimeInterval(-3600),
            matching: DateComponents(minute: 0, second: 0),
            matchingPolicy: .strict,
            direction: .forward
        ) ?? start
        while hour <= end {
            markers.append(hour)
            hour = hour.addingTimeInterval(3600)
        }
        return markers
    }

    private func formatHour(_ date: Date) -> String {
        let hour24 = calendar.component(.hour, from: date)
        if AppTimeFormat.current.is24 {
            return "\(hour24):00"
        }
        let meridiem = hour24 < 12 ? "am" : "pm"
        let hour12 = (hour24 % 12 == 0) ? 12 : (hour24 % 12)
        return "\(hour12) \(meridiem)"
    }

    private func formatTime(_ date: Date) -> String {
        let f = DateFormatter()
        if AppTimeFormat.current.is24 {
            f.dateFormat = "H:mm"
        } else {
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "h:mma"
            f.amSymbol = "am"
            f.pmSymbol = "pm"
        }
        return f.string(from: date)
    }
}
