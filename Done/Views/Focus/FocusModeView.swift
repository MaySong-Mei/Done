import SwiftUI

struct FocusModeView: View {
    let events: [Event]
    /// Invoked when the user requests to leave focus mode without rotating
    /// the device (the rotation-back path remains the natural exit when the
    /// device started in landscape; this covers manual-from-portrait, where
    /// rotating back to portrait can't be the exit because the user is
    /// already there). Background tap is the current trigger.
    var onExit: () -> Void = {}

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
                        .contentShape(Rectangle())
                        .onTapGesture { onExit() }

                    if let occ = current {
                        FocusModeEventView(
                            event: occ.event,
                            range: occ.range,
                            now: now,
                            allOccurrences: allToday,
                            isPortrait: isPortrait
                        )
                    } else {
                        FocusModeClockView(
                            now: now,
                            allOccurrences: allToday,
                            isPortrait: isPortrait
                        )
                    }
                }
                .foregroundStyle(Color(.label))
            }
        }
    }
}
