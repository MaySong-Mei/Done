import SwiftUI

struct FocusModeView: View {
    let events: [Event]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = context.date
            let allToday = CalendarLayout.occurrencesForDate(events, date: now)
            let current = allToday.first { $0.range.start <= now && $0.range.end > now }

            ZStack {
                Color.white
                    .ignoresSafeArea()

                if let occ = current {
                    FocusModeEventView(
                        event: occ.event,
                        range: occ.range,
                        now: now,
                        allOccurrences: allToday
                    )
                } else {
                    FocusModeClockView(now: now)
                }
            }
            .foregroundStyle(.black)
        }
    }
}
