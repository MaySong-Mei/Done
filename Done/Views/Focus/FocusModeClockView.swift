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

    private var previousOccurrence: CalendarLayout.EventOccurrence? {
        allOccurrences
            .filter { $0.range.end <= now }
            .max(by: { $0.range.end < $1.range.end })
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

    var body: some View {
        if isPortrait {
            portraitLayout
        } else {
            landscapeLayout
        }
    }

    private var portraitLayout: some View {
        VStack(spacing: 16) {
            FocusAmbientChip(
                kind: .previous,
                occurrence: previousOccurrence,
                referenceDate: now
            )
            .padding(.top, 8)

            Spacer()

            clockBlock(timeSize: 80, secondsSize: 30)
            idleBadge

            Spacer()

            FocusAmbientChip(
                kind: .next,
                occurrence: nextOccurrence,
                referenceDate: now
            )
            .padding(.bottom, 8)
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaPadding(.vertical)
    }

    private var landscapeLayout: some View {
        VStack(spacing: 16) {
            Spacer()
            clockBlock(timeSize: 96, secondsSize: 36)
            idleBadge

            if let next = nextOccurrence {
                FocusAmbientChip(
                    kind: .next,
                    occurrence: next,
                    referenceDate: now
                )
                .frame(maxWidth: 480)
                .padding(.top, 8)
            }
            Spacer()
        }
        .padding(.horizontal, 32)
    }

    @ViewBuilder
    private func clockBlock(timeSize: CGFloat, secondsSize: CGFloat) -> some View {
        VStack(spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(timeString)
                    .font(.system(size: timeSize, weight: .thin, design: .rounded))
                    .monospacedDigit()
                Text(secondsString)
                    .font(.system(size: secondsSize, weight: .thin, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            Text(dateString)
                .font(.system(size: 20, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var idleBadge: some View {
        if let idle = idleDuration {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color.secondary.opacity(0.6))
                    .frame(width: 8, height: 8)
                Text("Idle \(compactDuration(idle))")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.secondary.opacity(0.12)))
        } else {
            Text("Free")
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.secondary.opacity(0.12)))
        }
    }
}
