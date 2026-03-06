import SwiftUI

struct FocusModeView: View {
    let events: [Event]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = context.date
            let current = currentOccurrence(at: now)

            ZStack {
                Color.black
                    .ignoresSafeArea()

                if let occ = current {
                    FocusModeEventView(event: occ.event, range: occ.range, now: now)
                } else {
                    FocusModeClockView(now: now)
                }
            }
            .foregroundStyle(.white)
        }
    }

    private func currentOccurrence(at now: Date) -> CalendarLayout.EventOccurrence? {
        let today = CalendarLayout.occurrencesForDate(events, date: now)
        return today.first { $0.range.start <= now && $0.range.end > now }
    }
}
