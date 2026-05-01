import SwiftUI

/// Compact pill that surfaces the immediately-adjacent event on either
/// side of "now" (or, in event mode, on either side of the current
/// focused event). Used by both the event view and the empty-state clock
/// view so the two share one ambient-context vocabulary.
struct FocusAmbientChip: View {
    enum Kind {
        case previous
        case next
    }

    let kind: Kind
    /// The neighbor occurrence to surface. When nil the chip collapses
    /// to an empty view — callers don't need to gate visibility.
    let occurrence: CalendarLayout.EventOccurrence?
    /// The anchor used to compute relative time. For `previous` this is
    /// usually `now`; for `next` it can be `now` (in empty state) or
    /// the current event's end (in event mode), since "next" should be
    /// measured from when the current event finishes, not from now.
    let referenceDate: Date

    private var color: Color {
        guard let occurrence else { return .secondary }
        return CalendarLayout.eventColor(for: occurrence.event)
    }

    private var labelText: String {
        guard let occurrence else { return "" }
        switch kind {
        case .previous:
            let elapsed = referenceDate.timeIntervalSince(occurrence.range.end)
            return "Just finished · \(compactDuration(elapsed)) ago"
        case .next:
            let until = occurrence.range.start.timeIntervalSince(referenceDate)
            if until <= 0 {
                return "Next · now"
            }
            return "Next · in \(compactDuration(until))"
        }
    }

    private var timeText: String {
        guard let occurrence else { return "" }
        let target: Date
        switch kind {
        case .previous: target = occurrence.range.end
        case .next: target = occurrence.range.start
        }
        let f = DateFormatter()
        if AppTimeFormat.current.is24 {
            f.dateFormat = "H:mm"
        } else {
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "h:mm a"
            f.amSymbol = "am"
            f.pmSymbol = "pm"
        }
        return f.string(from: target)
    }

    private func compactDuration(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 {
            return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
        }
        return "\(max(0, minutes))m"
    }

    var body: some View {
        if let occurrence {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(color)
                    .frame(width: 4, height: 36)

                VStack(alignment: .leading, spacing: 2) {
                    Text(labelText)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)

                    Text(occurrence.event.title)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                Text(timeText)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.secondary.opacity(0.08))
            )
        } else {
            EmptyView()
        }
    }
}
