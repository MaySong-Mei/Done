import WidgetKit
import SwiftUI

// MARK: - Shared Entry & Provider

struct DoneWidgetEntry: TimelineEntry {
    let date: Date
    let events: [SharedEventSnapshot]
}

struct DoneWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> DoneWidgetEntry {
        DoneWidgetEntry(date: .now, events: Self.sampleEvents)
    }

    func getSnapshot(in context: Context, completion: @escaping (DoneWidgetEntry) -> Void) {
        completion(DoneWidgetEntry(date: .now, events: todayEvents()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<DoneWidgetEntry>) -> Void) {
        let entry = DoneWidgetEntry(date: .now, events: todayEvents())
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 5, to: .now) ?? .now
        completion(Timeline(entries: [entry], policy: .after(nextUpdate)))
    }

    private func todayEvents() -> [SharedEventSnapshot] {
        let all = SharedWidgetData.read()
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: .now)
        let todayEnd = calendar.date(byAdding: .day, value: 1, to: todayStart) ?? todayStart
        return all
            .filter { $0.endDate > todayStart && $0.startDate < todayEnd && !$0.isAllDay }
            .sorted { $0.startDate < $1.startDate }
    }

    static let sampleEvents: [SharedEventSnapshot] = {
        let cal = Calendar.current
        let now = Date.now
        return [
            SharedEventSnapshot(
                id: UUID(), title: "Deep Focus", type: "Deep Work",
                startDate: cal.date(byAdding: .hour, value: -1, to: now) ?? now,
                endDate: cal.date(byAdding: .hour, value: 2, to: now) ?? now,
                isAllDay: false, isDone: false
            ),
            SharedEventSnapshot(
                id: UUID(), title: "Team Standup", type: "Meeting",
                startDate: cal.date(byAdding: .hour, value: 3, to: now) ?? now,
                endDate: cal.date(byAdding: .hour, value: 4, to: now) ?? now,
                isAllDay: false, isDone: false
            ),
        ]
    }()
}

// MARK: - Helpers

private func snapshotColor(_ snapshot: SharedEventSnapshot) -> Color {
    if let hex = snapshot.colorHex {
        return hexToColor(hex)
    }
    let colors: [Color] = [.blue, .orange, .purple, .green, .pink, .teal, .indigo, .mint, .cyan, .red]
    let hash = abs(snapshot.type.hashValue)
    return colors[hash % colors.count]
}

private func hexToColor(_ hex: String) -> Color {
    let sanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
    guard let value = UInt64(sanitized, radix: 16) else { return .secondary }
    switch sanitized.count {
    case 6:
        let r = Double((value >> 16) & 0xFF) / 255.0
        let g = Double((value >> 8) & 0xFF) / 255.0
        let b = Double(value & 0xFF) / 255.0
        return Color(red: r, green: g, blue: b)
    case 8:
        let r = Double((value >> 24) & 0xFF) / 255.0
        let g = Double((value >> 16) & 0xFF) / 255.0
        let b = Double((value >> 8) & 0xFF) / 255.0
        let a = Double(value & 0xFF) / 255.0
        return Color(red: r, green: g, blue: b, opacity: a)
    default:
        return .secondary
    }
}

private var widgetIs24Hour: Bool {
    SharedWidgetData.sharedDefaults?.string(forKey: SharedWidgetData.timeFormatKey) ?? "24h" == "24h"
}

private var widgetLocale: Locale {
    let lang = SharedWidgetData.sharedDefaults?.string(forKey: SharedWidgetData.languageKey) ?? "en"
    return lang == "zh" ? Locale(identifier: "zh_CN") : Locale(identifier: "en")
}

private func currentEvent(in entry: DoneWidgetEntry) -> SharedEventSnapshot? {
    entry.events.first { $0.startDate <= entry.date && $0.endDate > entry.date && !$0.isDone }
}

private func nextUpEvent(in entry: DoneWidgetEntry) -> SharedEventSnapshot? {
    entry.events.first { $0.startDate > entry.date && !$0.isDone }
}

private func formatTime(_ date: Date) -> String {
    let f = DateFormatter()
    if widgetIs24Hour {
        f.dateFormat = "H:mm"
    } else {
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "h:mma"
        f.amSymbol = "am"
        f.pmSymbol = "pm"
    }
    return f.string(from: date)
}

// MARK: - 1. Progress Ring Widget (Small)

struct ProgressRingWidgetView: View {
    let entry: DoneWidgetEntry

    private var event: SharedEventSnapshot? {
        currentEvent(in: entry) ?? nextUpEvent(in: entry)
    }

    var body: some View {
        if let event {
            let isCurrent = event.startDate <= entry.date && event.endDate > entry.date
            let total = event.endDate.timeIntervalSince(event.startDate)
            let elapsed = max(0, entry.date.timeIntervalSince(event.startDate))
            let progress = isCurrent ? min(1, elapsed / max(1, total)) : 0
            let remaining = max(0, event.endDate.timeIntervalSince(entry.date))
            let color = snapshotColor(event)

            VStack(spacing: 8) {
                Text("\(formatTime(event.startDate)) – \(formatTime(event.endDate))")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                ZStack {
                    Circle()
                        .stroke(color.opacity(0.2), lineWidth: 6)
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(color, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .rotationEffect(.degrees(-90))

                    if isCurrent {
                        Text(remainingText(remaining))
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    } else {
                        Text(L(.next))
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 80, height: 80)

                Text(event.title)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 6)
                    Text("--")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                .frame(width: 80, height: 80)
                Text(L(.noEvents))
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func remainingText(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        if mins >= 60 {
            let h = mins / 60
            let m = mins % 60
            return m > 0 ? "\(h)h \(m)m left" : "\(h)h left"
        }
        return "\(max(1, mins))m left"
    }
}

struct ProgressRingWidget: Widget {
    let kind = "DoneProgressRingWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: DoneWidgetProvider()) { entry in
            ProgressRingWidgetView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName(L(.focusRing))
        .description(L(.focusRingDesc))
        .supportedFamilies([.systemSmall])
    }
}

// MARK: - 2. Mini Timeline Widget (Small)

struct MiniTimelineWidgetView: View {
    let entry: DoneWidgetEntry

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let w = geo.size.width
            let visibleHours: CGFloat = 6
            let now = entry.date
            let calendar = Calendar.current
            let pps = h / (visibleHours * 3600)
            let nowY = h * 0.4
            let labelWidth: CGFloat = 36
            let eventLeft = labelWidth
            let eventWidth = w - eventLeft - 4

            let windowStart = now.addingTimeInterval(-Double(visibleHours) * 3600 * 0.4)
            let windowEnd = now.addingTimeInterval(Double(visibleHours) * 3600 * 0.6)

            let hours = hourMarkers(from: windowStart, to: windowEnd, calendar: calendar)
            let nowMinutes = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)

            ZStack(alignment: .topLeading) {
                // Hour grid lines + labels
                ForEach(Array(hours.enumerated()), id: \.offset) { _, hour in
                    let y = nowY + CGFloat(hour.timeIntervalSince(now)) * pps
                    let hourMinutes = calendar.component(.hour, from: hour) * 60

                    if y > -10 && y < h + 10 {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.2))
                            .frame(width: eventWidth, height: 0.5)
                            .offset(x: eventLeft, y: y)

                        if abs(hourMinutes - nowMinutes) > 20 {
                            Text(formatHour(hour, calendar: calendar))
                                .font(.system(size: 7, weight: .semibold, design: .rounded))
                                .foregroundStyle(.secondary)
                                .offset(x: 1, y: y - 5)
                        }
                    }
                }

                // Current time label
                Text(formatTime(now))
                    .font(.system(size: 7, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.primary)
                    .offset(x: 1, y: nowY - 5)

                // Event blocks (with overlap columns)
                let columns = assignColumns(entry.events)
                let gap: CGFloat = 2

                // Draw non-interrupt events first, then interrupts on top
                ForEach(Array(columns.enumerated()), id: \.offset) { idx, col in
                    let event = entry.events[idx]
                    if event.isInterrupt != true {
                        let blockTop = nowY + CGFloat(event.startDate.timeIntervalSince(now)) * pps
                        let blockH = CGFloat(event.endDate.timeIntervalSince(event.startDate)) * pps
                        let color = snapshotColor(event)
                        let colWidth = max(0, eventWidth / CGFloat(col.total))
                        let colX = eventLeft + colWidth * CGFloat(col.index)

                        if blockTop + blockH > -10 && blockTop < h + 10 {
                            let titleInset = max(3, -blockTop + 3)
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(color.opacity(0.4))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .stroke(color.opacity(0.7), lineWidth: 1)
                                )
                                .frame(width: max(0, colWidth - gap), height: max(4, blockH - 2))
                                .overlay(alignment: .topLeading) {
                                    if blockH > 10 {
                                        Text(event.title)
                                            .font(.system(size: 8, weight: .semibold))
                                            .lineLimit(1)
                                            .padding(.horizontal, 4)
                                            .padding(.top, titleInset)
                                    }
                                }
                                .offset(x: colX, y: blockTop + 1)
                        }
                    }
                }

                // Interrupt events: left-indented within parent's column (like main app)
                ForEach(Array(columns.enumerated()), id: \.offset) { idx, col in
                    let event = entry.events[idx]
                    if event.isInterrupt == true, let parentID = event.parentEventID {
                        let blockTop = nowY + CGFloat(event.startDate.timeIntervalSince(now)) * pps
                        let blockH = CGFloat(event.endDate.timeIntervalSince(event.startDate)) * pps
                        let color = snapshotColor(event)

                        // Find parent's column info
                        let parentIdx = entry.events.firstIndex(where: { $0.id == parentID })
                        let parentCol = parentIdx.map { columns[$0] } ?? col
                        let colWidth = max(0, eventWidth / CGFloat(parentCol.total))
                        let colX = eventLeft + colWidth * CGFloat(parentCol.index)
                        // Left indent only (like main app's leadingInset: 8, scaled for widget)
                        let leadingInset: CGFloat = 4
                        let interruptWidth = max(0, colWidth - gap - leadingInset)

                        if blockTop + blockH > -10 && blockTop < h + 10 {
                            let titleInset = max(2, -blockTop + 2)
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(color.opacity(0.4))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                                        .stroke(color, lineWidth: 1.2)
                                )
                                .frame(width: interruptWidth, height: max(4, blockH - 2))
                                .overlay(alignment: .topLeading) {
                                    if blockH > 10 {
                                        Text(event.title)
                                            .font(.system(size: 8, weight: .semibold))
                                            .lineLimit(1)
                                            .padding(.horizontal, 3)
                                            .padding(.top, titleInset)
                                    }
                                }
                                .offset(x: colX + leadingInset, y: blockTop + 1)
                        }
                    }
                }

                // Now indicator
                Circle()
                    .fill(Color.primary)
                    .frame(width: 6, height: 6)
                    .offset(x: eventLeft - 3, y: nowY - 3)
                Rectangle()
                    .fill(Color.primary)
                    .frame(width: eventWidth + 4, height: 1)
                    .offset(x: eventLeft, y: nowY - 0.5)
            }
        }
        .clipped()
    }

    private func hourMarkers(from start: Date, to end: Date, calendar: Calendar) -> [Date] {
        var markers: [Date] = []
        var hour = calendar.nextDate(
            after: start.addingTimeInterval(-3600),
            matching: DateComponents(minute: 0, second: 0),
            matchingPolicy: .strict,
            direction: .forward
        ) ?? start
        while hour <= end {
            markers.append(hour)
            hour = hour.addingTimeInterval(3600)
        }
        return markers
    }

    private struct ColumnSlot {
        let index: Int
        let total: Int
    }

    private func assignColumns(_ events: [SharedEventSnapshot]) -> [ColumnSlot] {
        var slots = Array(repeating: ColumnSlot(index: 0, total: 1), count: events.count)
        for i in events.indices {
            // Interrupts always occupy full width (they overlay on top of their parent)
            if events[i].isInterrupt == true { continue }
            var overlapping: [Int] = [i]
            for j in events.indices where j != i {
                // Skip interrupts — they don't participate in column splitting
                if events[j].isInterrupt == true { continue }
                if events[i].startDate < events[j].endDate && events[j].startDate < events[i].endDate {
                    overlapping.append(j)
                }
            }
            overlapping.sort()
            let total = overlapping.count
            if let pos = overlapping.firstIndex(of: i) {
                slots[i] = ColumnSlot(index: pos, total: total)
            }
        }
        return slots
    }

    private func formatHour(_ date: Date, calendar: Calendar) -> String {
        let hour24 = calendar.component(.hour, from: date)
        if widgetIs24Hour {
            return "\(hour24):00"
        }
        let meridiem = hour24 < 12 ? "am" : "pm"
        let hour12 = (hour24 % 12 == 0) ? 12 : (hour24 % 12)
        return "\(hour12) \(meridiem)"
    }
}

struct MiniTimelineWidget: Widget {
    let kind = "DoneMiniTimelineWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: DoneWidgetProvider()) { entry in
            MiniTimelineWidgetView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName(L(.miniTimeline))
        .description(L(.miniTimelineDesc))
        .supportedFamilies([.systemSmall])
    }
}

// MARK: - 3. Timeline Bar Widget (Small)

struct TimelineBarWidgetView: View {
    let entry: DoneWidgetEntry

    private var event: SharedEventSnapshot? {
        currentEvent(in: entry) ?? nextUpEvent(in: entry)
    }

    var body: some View {
        if let event {
            let isCurrent = event.startDate <= entry.date && event.endDate > entry.date
            let total = event.endDate.timeIntervalSince(event.startDate)
            let elapsed = max(0, entry.date.timeIntervalSince(event.startDate))
            let progress = isCurrent ? min(1, elapsed / max(1, total)) : 0

            VStack(alignment: .leading, spacing: 8) {
                Text(isCurrent ? L(.timeline) : L(.upNext))
                    .font(.system(size: 15, weight: .semibold, design: .rounded))

                Text(event.title)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Text(formatTime(entry.date))
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .monospacedDigit()

                Spacer(minLength: 0)

                // Progress bar
                GeometryReader { geo in
                    let trackW = geo.size.width
                    let thumbX = trackW * progress

                    ZStack(alignment: .leading) {
                        // Background track
                        Capsule()
                            .fill(Color.secondary.opacity(0.25))
                            .frame(height: 4)

                        // Filled portion
                        Capsule()
                            .fill(Color.primary.opacity(0.6))
                            .frame(width: max(0, thumbX), height: 4)

                        // Thumb
                        if isCurrent {
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(Color.primary)
                                .frame(width: 3, height: 14)
                                .offset(x: max(0, thumbX - 1.5))
                        }
                    }
                    .frame(height: 14)
                }
                .frame(height: 14)

                HStack {
                    Text(formatTime(event.startDate))
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Spacer()
                    Text(formatTime(event.endDate))
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text(L(.timeline))
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                Text(formatTime(entry.date))
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Spacer()
                Text(L(.noEvents))
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

struct TimelineBarWidget: Widget {
    let kind = "DoneTimelineBarWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: DoneWidgetProvider()) { entry in
            TimelineBarWidgetView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName(L(.timelineBar))
        .description(L(.timelineBarDesc))
        .supportedFamilies([.systemSmall])
    }
}

// MARK: - 4. Original Event List Widget (Small + Medium)

struct DoneWidgetSmallView: View {
    let entry: DoneWidgetEntry

    private var event: SharedEventSnapshot? {
        currentEvent(in: entry) ?? nextUpEvent(in: entry)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(dayString)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(entry.events.count)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.1), in: Capsule())
            }

            Spacer(minLength: 0)

            if let event {
                let isCurrent = event.startDate <= entry.date && event.endDate > entry.date
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(snapshotColor(event))
                            .frame(width: 6, height: 6)
                        Text(isCurrent ? L(.now) : L(.next))
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                    Text(event.title)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("\(formatTime(event.startDate)) – \(formatTime(event.endDate))")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            } else {
                Text(L(.noMoreEvents))
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var dayString: String {
        let f = DateFormatter()
        f.locale = widgetLocale
        f.setLocalizedDateFormatFromTemplate("EEEMMMd")
        return f.string(from: entry.date)
    }
}

struct DoneWidgetMediumView: View {
    let entry: DoneWidgetEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(dayString)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(entry.events.count) events")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            if entry.events.isEmpty {
                Spacer()
                Text(L(.noEventsToday))
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer()
            } else {
                ForEach(Array(entry.events.prefix(4).enumerated()), id: \.element.id) { _, event in
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(snapshotColor(event))
                            .frame(width: 3, height: 28)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(event.title)
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .lineLimit(1)
                                .strikethrough(event.isDone)
                                .foregroundStyle(event.isDone ? .secondary : .primary)
                            Text(shortTimeString(event))
                                .font(.system(size: 10, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }

                        Spacer(minLength: 0)

                        if event.startDate <= entry.date && event.endDate > entry.date && !event.isDone {
                            Text(L(.now).uppercased())
                                .font(.system(size: 9, weight: .bold, design: .rounded))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(snapshotColor(event).opacity(0.2), in: Capsule())
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var dayString: String {
        let f = DateFormatter()
        f.locale = widgetLocale
        f.setLocalizedDateFormatFromTemplate("EEEEMMMd")
        return f.string(from: entry.date)
    }

    private func shortTimeString(_ event: SharedEventSnapshot) -> String {
        if event.isAllDay { return "All day" }
        return "\(formatTime(event.startDate)) – \(formatTime(event.endDate))"
    }
}

struct DoneWidget: Widget {
    let kind = "DoneWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: DoneWidgetProvider()) { entry in
            DoneWidgetEntryView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Done")
        .description(L(.doneWidgetDesc))
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct DoneWidgetEntryView: View {
    @Environment(\.widgetFamily) var family
    let entry: DoneWidgetEntry

    var body: some View {
        switch family {
        case .systemSmall:
            DoneWidgetSmallView(entry: entry)
        default:
            DoneWidgetMediumView(entry: entry)
        }
    }
}
