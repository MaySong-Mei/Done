import SwiftUI

struct FocusModeClockView: View {
    let now: Date
    var allOccurrences: [CalendarLayout.EventOccurrence] = []
    var isPortrait: Bool = false

    private var calendar: Calendar { .current }

    private var timeString: String {
        let f = DateFormatter()
        if AppTimeFormat.current.is24 {
            f.dateFormat = "HH:mm"
        } else {
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "h:mm a"
            f.amSymbol = "am"
            f.pmSymbol = "pm"
        }
        return f.string(from: now)
    }

    private var secondsString: String {
        let s = calendar.component(.second, from: now)
        return String(format: "%02d", s)
    }

    private var dateString: String {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMMM d"
        return f.string(from: now)
    }

    private var idleDuration: TimeInterval? {
        let latestPastEnd = allOccurrences
            .map { $0.range.end }
            .filter { $0 <= now }
            .max()
        guard let latestPastEnd else { return nil }
        return now.timeIntervalSince(latestPastEnd)
    }

    private var nextOccurrence: CalendarLayout.EventOccurrence? {
        allOccurrences
            .filter { $0.range.start > now }
            .min(by: { $0.range.start < $1.range.start })
    }

    private func compactDuration(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 {
            return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
        }
        return "\(minutes)m"
    }

    private func clockTimeText(_ date: Date) -> String {
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
        VStack(spacing: isPortrait ? 24 : 16) {
            Spacer()

            VStack(spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(timeString)
                        .font(.system(size: isPortrait ? 80 : 96, weight: .thin, design: .rounded))
                        .monospacedDigit()
                    Text(secondsString)
                        .font(.system(size: isPortrait ? 30 : 36, weight: .thin, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                Text(dateString)
                    .font(.system(size: 20, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            statusCard

            Spacer()
        }
        .padding(.horizontal, 32)
    }

    @ViewBuilder
    private var statusCard: some View {
        VStack(spacing: 16) {
            if let idle = idleDuration {
                idleBadge(duration: idle)
            } else {
                Text("Free")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.secondary.opacity(0.12)))
            }

            if let next = nextOccurrence {
                nextEventRow(occurrence: next)
            }
        }
        .frame(maxWidth: 480)
    }

    private func idleBadge(duration: TimeInterval) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.secondary.opacity(0.6))
                .frame(width: 8, height: 8)
            Text("Idle \(compactDuration(duration))")
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.secondary.opacity(0.12)))
    }

    private func nextEventRow(occurrence: CalendarLayout.EventOccurrence) -> some View {
        let timeUntil = occurrence.range.start.timeIntervalSince(now)
        let color = CalendarLayout.eventColor(for: occurrence.event)

        return HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(color)
                .frame(width: 4)

            VStack(alignment: .leading, spacing: 2) {
                Text("Next · in \(compactDuration(timeUntil))")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)

                Text(occurrence.event.title)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .lineLimit(1)

                Text(clockTimeText(occurrence.range.start))
                    .font(.system(size: 13, weight: .regular, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        )
    }
}
