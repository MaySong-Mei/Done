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
    /// Quick-record: start a new event of the given type at "now".
    /// Caller decides default duration / title; focus mode just
    /// surfaces the type choice.
    var onStartTracking: (EventTypeTemplate) -> Void = { _ in }

    @State private var dragOffsetY: CGFloat = 0

    private let dismissThreshold: CGFloat = 120

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = context.date
            let allToday = CalendarLayout.occurrencesForDate(events, date: now)
            let current = allToday.first { $0.range.start <= now && $0.range.end > now }

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
                            onExtend: { delta in onExtendCurrent(occ.event, delta) },
                            onEndNow: { onEndCurrent(occ.event, now) },
                            onUpdateTitle: { title in onUpdateTitleForCurrent(occ.event, title) }
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
