import SwiftUI

struct FocusModeEventView: View {
    let event: Event
    let range: Event.TimeRange
    let now: Date
    let allOccurrences: [CalendarLayout.EventOccurrence]
    var isPortrait: Bool = false
    /// When false, the quick-action row is hidden because the current event
    /// can't be safely mutated by the simple `+15 / End now` paths (e.g. it's
    /// a recurring occurrence that would need scope-aware editing). Caller
    /// decides via `focusQuickActionAllowedForEvent`.
    var quickActionsEnabled: Bool = true
    /// Quick-action: extend the current event's end by the supplied delta
    /// (in seconds). Caller decides whether to apply to the series or the
    /// occurrence.
    var onExtend: (TimeInterval) -> Void = { _ in }
    /// Quick-action: end the current event at "now".
    var onEndNow: () -> Void = {}

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

    private var previousOccurrence: CalendarLayout.EventOccurrence? {
        allOccurrences
            .filter { $0.range.end <= now && $0.event.id != event.id }
            .max(by: { $0.range.end < $1.range.end })
    }

    private var nextOccurrence: CalendarLayout.EventOccurrence? {
        allOccurrences
            .filter { $0.range.start >= range.end }
            .min(by: { $0.range.start < $1.range.start })
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
                quickActionRow
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
        }
    }

    private var portraitLayout: some View {
        // Symmetric: prev chip on top, big protagonist centered, next chip
        // on bottom. Keeps the focus on the current event without competing
        // with a full mini-timeline (the calendar tab already covers that
        // role). Same chip vocabulary as the empty-state clock view, so
        // the two states feel like one design.
        VStack(spacing: 16) {
            if previousOccurrence != nil {
                FocusAmbientChip(
                    kind: .previous,
                    occurrence: previousOccurrence,
                    referenceDate: now
                )
            }

            Spacer()

            VStack(spacing: 20) {
                eventDetailStack(titleSize: 36, ringSize: 200)
                quickActionRow
            }

            Spacer()

            if nextOccurrence != nil {
                FocusAmbientChip(
                    kind: .next,
                    occurrence: nextOccurrence,
                    referenceDate: range.end
                )
                .padding(.bottom, 8)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaPadding(.vertical)
    }

    @ViewBuilder
    private var quickActionRow: some View {
        if quickActionsEnabled {
            HStack(spacing: 12) {
                actionPill(label: "+15 min", systemImage: "clock.arrow.circlepath") {
                    onExtend(15 * 60)
                }
                actionPill(label: "End now", systemImage: "stop.circle", role: .destructive) {
                    onEndNow()
                }
            }
        }
    }

    private func actionPill(
        label: String,
        systemImage: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                Text(label)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(role == .destructive ? Color.red : Color.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                Capsule().fill(
                    role == .destructive
                        ? Color.red.opacity(0.10)
                        : Color.secondary.opacity(0.12)
                )
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func eventDetailStack(titleSize: CGFloat, ringSize: CGFloat) -> some View {
        Text(event.type)
            .font(.system(size: 14, weight: .semibold, design: .rounded))
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(Capsule().fill(eventColor))

        Text(event.title.isEmpty ? "Untitled" : event.title)
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
