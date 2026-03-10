import SwiftUI

// MARK: - Event Flow (left side — ambient time context)

/// Events floating in a time stream. Not a calendar grid —
/// a living, slowly drifting visualization of time passing.
struct FocusEventFlowView: View {
    let currentEvent: Event
    let currentRange: Event.TimeRange
    let now: Date
    let allOccurrences: [CalendarLayout.EventOccurrence]

    // Visible time window
    private let visibleHours: CGFloat = 6

    private let calendar = Calendar.current

    // The event area starts at 20% from left (after time labels) and uses 76% of width
    private let eventAreaStart: CGFloat = 0.20
    private let eventAreaWidth: CGFloat = 0.76

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let w = geo.size.width

            // Pixels per second for the visible window
            let pps = h / (visibleHours * 3600)

            // "now" anchored at 40% from top — past above, future below
            let nowY = h * 0.4

            // Time labels: full hours in the visible window
            let windowStart = now.addingTimeInterval(-Double(visibleHours) * 3600 * 0.4)
            let windowEnd = now.addingTimeInterval(Double(visibleHours) * 3600 * 0.6)

            // Compute overlap layout — same algorithm as calendar
            let overlapSlots = CalendarLayout.overlapLayout(
                for: allOccurrences,
                on: now,
                calendar: calendar
            )

            ZStack(alignment: .topLeading) {
                // Hour time labels — floating softly
                ForEach(hourMarkers(from: windowStart, to: windowEnd), id: \.self) { hour in
                    let y = nowY + CGFloat(hour.timeIntervalSince(now)) * pps
                    Text(formatHour(hour))
                        .font(.system(size: 11, weight: .regular, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.25))
                        .position(x: w * 0.10, y: y)
                }

                // Event blocks — with overlap columns
                ForEach(allOccurrences, id: \.id) { occ in
                    let color = CalendarLayout.eventColor(for: occ.event)
                    let isCurrent = occ.event.id == currentEvent.id
                        && occ.range.start == currentRange.start
                    let blockTop = nowY + CGFloat(occ.range.start.timeIntervalSince(now)) * pps
                    let blockH = CGFloat(occ.range.end.timeIntervalSince(occ.range.start)) * pps
                    let blockBottom = blockTop + blockH
                    let slot = overlapSlots[occ.id] ?? .default

                    // Only render if visible
                    if blockBottom > -20 && blockTop < h + 20 {
                        eventCard(
                            title: occ.event.title,
                            color: color,
                            isCurrent: isCurrent,
                            top: blockTop,
                            height: blockH,
                            totalWidth: w,
                            slot: slot
                        )
                    }
                }

                // "Now" line
                let lineLeft = w * eventAreaStart
                Circle()
                    .fill(.white.opacity(0.9))
                    .frame(width: 6, height: 6)
                    .position(x: lineLeft, y: nowY)

                Rectangle()
                    .fill(.white.opacity(0.4))
                    .frame(width: w * eventAreaWidth, height: 1)
                    .position(x: lineLeft + w * eventAreaWidth / 2, y: nowY)
            }
        }
        .clipped()
    }

    // MARK: - Event card

    @ViewBuilder
    private func eventCard(
        title: String,
        color: Color,
        isCurrent: Bool,
        top: CGFloat,
        height: CGFloat,
        totalWidth: CGFloat,
        slot: CalendarLayout.EventOverlapSlot
    ) -> some View {
        let areaX = totalWidth * eventAreaStart
        let areaW = totalWidth * eventAreaWidth
        let cardX = areaX + areaW * slot.xOffsetFraction
        let cardW = areaW * slot.widthFraction - 2 // 2pt gap between columns
        let opacity: Double = isCurrent ? 0.4 : 0.15
        let cardH = max(height, 24)

        RoundedRectangle(cornerRadius: 10)
            .fill(color.opacity(opacity))
            .frame(width: max(cardW, 0), height: cardH)
            .overlay(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(color.opacity(isCurrent ? 1 : 0.5))
                    .frame(width: 3, height: cardH)
            }
            .overlay(alignment: .topLeading) {
                if height > 28 {
                    Text(title)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(isCurrent ? color : .white.opacity(0.4))
                        .lineLimit(1)
                        .padding(.leading, 10)
                        .padding(.top, 6)
                }
            }
            .position(x: cardX + max(cardW, 0) / 2, y: top + cardH / 2)
    }

    // MARK: - Helpers

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

    private static let hourFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "H:mm"
        return f
    }()

    private func formatHour(_ date: Date) -> String {
        Self.hourFormatter.string(from: date)
    }
}
