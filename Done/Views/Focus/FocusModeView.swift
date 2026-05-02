import SwiftUI

struct FocusModeView: View {
    let events: [Event]
    /// Available type templates surfaced in the empty-state's
    /// "Start tracking" row. Empty list hides the section entirely.
    var templates: [EventTypeTemplate] = []
    /// Invoked when the user requests to leave focus mode. Triggered by
    /// a deliberate swipe-down gesture (or by rotation back to portrait
    /// at the OrientationManager level when applicable). We deliberately
    /// avoid tap-to-exit because focus mode is a now-workspace where
    /// chips, the protagonist, and quick action buttons all want their
    /// own tap targets.
    var onExit: () -> Void = {}
    /// Adjust the current event's end time by the given delta.
    var onExtendCurrent: (Event, TimeInterval) -> Void = { _, _ in }
    /// End the current event at the given date (typically `now`).
    var onEndCurrent: (Event, Date) -> Void = { _, _ in }
    /// Inline title commit on the current event.
    var onUpdateTitleForCurrent: (Event, String) -> Void = { _, _ in }
    /// Append a focus-mode timeline note to the current event. Caller
    /// constructs the occurrence context and stamps the createdAt.
    var onAddNoteToCurrent: (CalendarLayout.EventOccurrence, String) -> Void = { _, _ in }
    /// Create an embedded interrupt under the current event for the given
    /// type. The new sub-event covers `now → now+15min` by default and
    /// becomes the resolved focus protagonist on the next tick.
    var onCreateInterruptForCurrent: (CalendarLayout.EventOccurrence, String) -> Void = { _, _ in }
    /// Quick-record: start a new event of the given type at "now".
    /// Caller decides default duration / title; focus mode just
    /// surfaces the type choice.
    var onStartTracking: (EventTypeTemplate) -> Void = { _ in }

    @State private var dragOffsetY: CGFloat = 0

    private let dismissThreshold: CGFloat = 120
    /// How long after `range.end` an event is still resolved as the
    /// focus session's "current" event. Without this, an event silently
    /// drops out the moment its scheduled end passes — the user has no
    /// chance to see "Xm over" or to act (extend, mark complete) from
    /// the same surface they'd been working on. The window matches what
    /// a user typically takes to look up at the screen and react.
    private let overrunGraceWindow: TimeInterval = 5 * 60

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = context.date
            let allToday = CalendarLayout.occurrencesForDate(events, date: now)
            let current = focusCurrentOccurrence(
                in: allToday,
                now: now,
                overrunGrace: overrunGraceWindow
            )

            GeometryReader { geo in
                let isPortrait = geo.size.height > geo.size.width

                ZStack {
                    Color(.systemBackground)
                        .ignoresSafeArea()

                    if let occ = current {
                        FocusModeEventView(
                            event: occ.event,
                            range: occ.range,
                            now: now,
                            allOccurrences: allToday,
                            isPortrait: isPortrait,
                            quickActionsEnabled: focusQuickActionAllowedForEvent(occ.event),
                            templates: templates,
                            onExtend: { delta in onExtendCurrent(occ.event, delta) },
                            onEndNow: { onEndCurrent(occ.event, now) },
                            onUpdateTitle: { title in onUpdateTitleForCurrent(occ.event, title) },
                            onAddNote: { text in onAddNoteToCurrent(occ, text) },
                            onCreateInterrupt: { type in onCreateInterruptForCurrent(occ, type) }
                        )
                    } else {
                        FocusModeClockView(
                            now: now,
                            allOccurrences: allToday,
                            isPortrait: isPortrait,
                            templates: templates,
                            onStartTracking: onStartTracking
                        )
                    }
                }
                .foregroundStyle(Color(.label))
                .offset(y: max(0, dragOffsetY))
                .simultaneousGesture(
                    DragGesture(minimumDistance: 20)
                        .onChanged { value in
                            // Only track downward translation; ignore upward
                            // so users can't accidentally pull from the
                            // bottom and bounce.
                            dragOffsetY = max(0, value.translation.height)
                        }
                        .onEnded { value in
                            if value.translation.height > dismissThreshold {
                                onExit()
                            }
                            withAnimation(.easeOut(duration: 0.2)) {
                                dragOffsetY = 0
                            }
                        }
                )
            }
        }
    }
}

/// Resolve which occurrence focus mode treats as "the current event"
/// given the day's occurrences and the present moment.
///
/// Resolution precedence:
///   1. An embedded interrupt that covers `now` — when the user has
///      explicitly created a sub-event ("phone rang"), their attention
///      is on the interrupt, not the parent it overlaps. The protagonist
///      surface should follow.
///   2. Any other in-progress occurrence whose range covers `now`.
///   3. Most recently ended event within `overrunGrace` — the user has
///      briefly continued past the scheduled end and we want to keep
///      them on the same protagonist so they can decide (Extend / End /
///      let it expire).
///
/// Pure / testable. No UI side effects.
func focusCurrentOccurrence(
    in occurrences: [CalendarLayout.EventOccurrence],
    now: Date,
    overrunGrace: TimeInterval
) -> CalendarLayout.EventOccurrence? {
    let inProgress = occurrences.filter { $0.range.start <= now && $0.range.end > now }
    if let interrupt = inProgress.first(where: { occ in
        occ.event.displayKind == .interrupt
            && occ.event.interruptRelation?.state == .embedded
    }) {
        return interrupt
    }
    if let any = inProgress.first {
        return any
    }
    guard overrunGrace > 0 else { return nil }
    let cutoff = now.addingTimeInterval(-overrunGrace)
    return occurrences
        .filter { $0.range.end <= now && $0.range.end > cutoff }
        .max(by: { $0.range.end < $1.range.end })
}
