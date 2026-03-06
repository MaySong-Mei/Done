import SwiftUI

struct FocusModeClockView: View {
    let now: Date

    private var calendar: Calendar { .current }

    private var timeString: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
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

    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(timeString)
                    .font(.system(size: 96, weight: .thin, design: .rounded))
                    .monospacedDigit()
                Text(secondsString)
                    .font(.system(size: 36, weight: .thin, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            Text(dateString)
                .font(.system(size: 20, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
        }
    }
}
