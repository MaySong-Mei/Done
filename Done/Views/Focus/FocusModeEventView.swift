import SwiftUI

struct FocusModeEventView: View {
    let event: Event
    let range: Event.TimeRange
    let now: Date
    let allOccurrences: [CalendarLayout.EventOccurrence]
    var isPortrait: Bool = false

    private var eventColor: Color {
        CalendarLayout.eventColor(for: event)
    }

    private var elapsed: TimeInterval {
        max(0, now.timeIntervalSince(range.start))
    }

    private var total: TimeInterval {
        max(1, range.end.timeIntervalSince(range.start))
    }

    private var progress: Double {
        min(1, elapsed / total)
    }

    private var remainingText: String {
        let remaining = max(0, range.end.timeIntervalSince(now))
        let mins = Int(remaining) / 60
        if mins >= 60 {
            let h = mins / 60
            let m = mins % 60
            return m > 0 ? "\(h)h \(m)m left" : "\(h)h left"
        }
        return "\(mins)m left"
    }

    private func timeText(_ date: Date) -> String {
        let f = DateFormatter()
        if AppTimeFormat.current.is24 {
            f.dateFormat = "H:mm"
        } else {
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "h:mm a"
            f.amSymbol = "am"
            f.pmSymbol = "pm"
        }
        return f.string(from: date)
    }

    var body: some View {
        if isPortrait {
            portraitLayout
        } else {
            landscapeLayout
        }
    }

    private var landscapeLayout: some View {
        HStack(spacing: 0) {
            // Left: event flow — ambient time context
            FocusEventFlowView(
                currentEvent: event,
                currentRange: range,
                now: now,
                allOccurrences: allOccurrences
            )
            .frame(maxHeight: .infinity)
            .frame(maxWidth: .infinity)
            .padding(.leading, 48)

            // Right: focus session — protagonist
            VStack(spacing: 24) {
                Spacer()
                eventDetailStack(titleSize: 40, ringSize: 110)
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
        }
    }

    private var portraitLayout: some View {
        VStack(spacing: 0) {
            // Top: protagonist (event title / progress) so the eyes land
            // here first. Mirrors the landscape "right side is the focus."
            VStack(spacing: 20) {
                Spacer()
                eventDetailStack(titleSize: 32, ringSize: 140)
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)

            // Bottom: event flow as ambient context, smaller share of
            // vertical space than landscape's left column.
            FocusEventFlowView(
                currentEvent: event,
                currentRange: range,
                now: now,
                allOccurrences: allOccurrences
            )
            .frame(maxWidth: .infinity)
            .frame(height: 240)
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
    }

    @ViewBuilder
    private func eventDetailStack(titleSize: CGFloat, ringSize: CGFloat) -> some View {
        Text(event.type)
            .font(.system(size: 14, weight: .semibold, design: .rounded))
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(Capsule().fill(eventColor))

        Text(event.title)
            .font(.system(size: titleSize, weight: .semibold, design: .rounded))
            .lineLimit(2)
            .multilineTextAlignment(.center)

        Text("\(timeText(range.start)) – \(timeText(range.end))")
            .font(.system(size: 18, weight: .regular, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.secondary)

        ZStack {
            Circle()
                .stroke(eventColor.opacity(0.2), lineWidth: 8)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(eventColor, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .rotationEffect(.degrees(-90))

            Text(remainingText)
                .font(.system(size: 18, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .frame(width: ringSize, height: ringSize)
    }
}
