import SwiftUI

/// Timeline view matching portrait calendar style — current time ±2 hours.
struct FocusEventFlowView: View {
    let currentEvent: Event
    let currentRange: Event.TimeRange
    let now: Date
    let allOccurrences: [CalendarLayout.EventOccurrence]

    private let visibleHours: CGFloat = 4
    private let calendar = Calendar.current
    private let labelWidth: CGFloat = 42
    private let eventInset: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let w = geo.size.width
            let nowY = h * 0.5
            let pps = h / (visibleHours * 3600)
            let windowStart = now.addingTimeInterval(-Double(visibleHours) * 3600 * 0.5)
            let windowEnd = now.addingTimeInterval(Double(visibleHours) * 3600 * 0.5)

            let eventLeft = labelWidth
            let eventRight = w
            let eventW = eventRight - eventLeft

            let overlapSlots = CalendarLayout.overlapLayout(
                for: allOccurrences,
                on: now,
                calendar: calendar
            )

            let hours = hourMarkers(from: windowStart, to: windowEnd)

            ZStack(alignment: .topLeading) {
                // Grid lines + time labels
                ForEach(Array(hours.enumerated()), id: \.offset) { _, hour in
                    let y = nowY + CGFloat(hour.timeIntervalSince(now)) * pps

                    // Grid line
                    Rectangle()
                        .fill(Color(white: 0.85))
                        .frame(width: eventW - eventInset * 2, height: 1)
                        .offset(x: eventLeft + eventInset, y: y)

                    // Time label
                    Text(formatHour12(hour))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Color(white: 0.45))
                        .offset(x: 4, y: y - 7)
                }

                // Current time label
                Text(formatCurrentTime(now))
                    .font(.system(size: 9, weight: .bold).monospacedDigit())
                    .foregroundColor(Color(white: 0.22))
                    .offset(x: 4, y: nowY - 7)

                // Event blocks
                ForEach(allOccurrences, id: \.id) { occ in
                    let color = CalendarLayout.eventColor(for: occ.event)
                    let blockTop = nowY + CGFloat(occ.range.start.timeIntervalSince(now)) * pps
                    let blockH = CGFloat(occ.range.end.timeIntervalSince(occ.range.start)) * pps
                    let blockBottom = blockTop + blockH
                    let slot = overlapSlots[occ.id] ?? .default
                    let areaW = eventW - eventInset * 2
                    let overlapGap: CGFloat = slot.widthFraction < 1 ? 2 : 0
                    let blockW = areaW * slot.widthFraction - overlapGap
                    let blockX = eventLeft + eventInset + areaW * slot.xOffsetFraction

                    if blockBottom > -20 && blockTop < h + 20 {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.white)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(color.opacity(0.4))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .stroke(color.opacity(0.7), lineWidth: 1.2)
                            )
                            .overlay(alignment: .topLeading) {
                                if blockH >= 16 {
                                    Text(occ.event.title)
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundColor(.black)
                                        .lineLimit(2)
                                        .padding(.horizontal, 8)
                                        .padding(.top, blockH < 24 ? 0 : 8)
                                        .frame(maxHeight: max(blockH, 0), alignment: blockH < 24 ? .center : .topLeading)
                                }
                            }
                            .frame(width: max(0, blockW), height: max(0, blockH - 3))
                            .offset(x: blockX, y: blockTop + 1.5)
                    }
                }

                // Now indicator
                let nowColor = Color(white: 0.22)
                Circle()
                    .fill(nowColor)
                    .frame(width: 8, height: 8)
                    .offset(x: eventLeft + eventInset - 4, y: nowY - 4)
                Rectangle()
                    .fill(nowColor)
                    .frame(width: eventW - eventInset, height: 1.5)
                    .offset(x: eventLeft + eventInset, y: nowY - 0.75)
            }
        }
        .background(Color.white)
        .clipped()
    }

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

    private func formatHour12(_ date: Date) -> String {
        let hour24 = calendar.component(.hour, from: date)
        let meridiem = hour24 < 12 ? "am" : "pm"
        let hour12 = (hour24 % 12 == 0) ? 12 : (hour24 % 12)
        return "\(hour12) \(meridiem)"
    }

    private static let currentTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "H:mm"
        return f
    }()

    private func formatCurrentTime(_ date: Date) -> String {
        Self.currentTimeFormatter.string(from: date)
    }
}
