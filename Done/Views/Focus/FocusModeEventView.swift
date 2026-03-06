import SwiftUI

struct FocusModeEventView: View {
    let event: Event
    let range: Event.TimeRange
    let now: Date

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
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    var body: some View {
        VStack(spacing: 28) {
            // Event type label
            Text(event.type)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(Capsule().fill(eventColor))

            // Event title
            Text(event.title)
                .font(.system(size: 44, weight: .semibold, design: .rounded))
                .lineLimit(2)
                .multilineTextAlignment(.center)

            // Time range
            Text("\(timeText(range.start)) – \(timeText(range.end))")
                .font(.system(size: 20, weight: .regular, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)

            // Progress ring
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
            .frame(width: 120, height: 120)
        }
    }
}
