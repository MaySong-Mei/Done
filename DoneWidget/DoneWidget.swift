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
        let all = SharedWidgetData.read()
        completion(DoneWidgetEntry(
            date: .now,
            events: WidgetTimelineSchedule.events(visibleOn: .now, from: all, calendar: .current)
        ))
    }

    /// gh#219: a day of pre-delivered entries (event boundaries + 15-minute
    /// ticks + the day rollover), then `.atEnd` — roughly ONE requested
    /// refresh per day. The policy this replaced, `.after(now + 5 minutes)`,
    /// requested 288/day against WidgetKit's ~40-70/day budget, and once the
    /// budget was gone the app's own hash-guarded `reloadAllTimelines` push
    /// (the data-freshness path) got throttled too: the pull policy was what
    /// made the widget STALE. Re-rendering delivered entries is free; every
    /// view in this file renders from `entry.date`, so each entry advances
    /// the display without any refresh. Entry count is capped by
    /// `WidgetTimelineSchedule.maxEntryCount` — see its doc for the
    /// truncation rationale. The schedule itself is pure, shared, and tested
    /// from `DoneTests` (this target has no test bundle).
    func getTimeline(in context: Context, completion: @escaping (Timeline<DoneWidgetEntry>) -> Void) {
        let all = SharedWidgetData.read()
        let calendar = Calendar.current
        let now = Date.now
        let entries = WidgetTimelineSchedule.entryDates(events: all, now: now, calendar: calendar)
            .map { date in
                DoneWidgetEntry(
                    date: date,
                    events: WidgetTimelineSchedule.events(visibleOn: date, from: all, calendar: calendar)
                )
            }
        completion(Timeline(entries: entries, policy: .atEnd))
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
    return colors[WidgetLayout.paletteIndex(for: snapshot.type, count: colors.count)]
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

/// The locale the widget's *dates* format in.
///
/// `AppLanguage.current` now falls through to the App Group, so this and every
/// `L(...)` in this file resolve from the same value — they used to disagree,
/// and the widget rendered a Chinese date beside English chrome (gh#239 F5).
private var widgetLocale: Locale { AppLanguage.current.locale }

private func currentEvent(in entry: DoneWidgetEntry) -> SharedEventSnapshot? {
    entry.events.first { $0.startDate <= entry.date && $0.endDate > entry.date && !$0.isDone }
}

private func nextUpEvent(in entry: DoneWidgetEntry) -> SharedEventSnapshot? {
    entry.events.first { $0.startDate > entry.date && !$0.isDone }
}

extension View {
    /// One-line label that shrinks before it truncates.
    ///
    /// Every font in this file is a fixed `\.system(size:)` inside a content box
    /// the device chooses (116, 126 or 138pt square for the small families), so
    /// a label sized for the middle case truncates on the small one and wastes
    /// room on the large one. Before gh#239 F3 the file had 30 fixed sizes and
    /// not one `minimumScaleFactor`: anything that did not fit became `…`
    /// immediately, even when 10% would have fitted it.
    ///
    /// 0.7 is the floor at which the rounded 10-13pt faces here stay legible at
    /// arm's length; below that truncation is the kinder failure.
    func widgetFit(_ minimumScale: CGFloat = 0.7) -> some View {
        self.lineLimit(1).minimumScaleFactor(minimumScale).allowsTightening(true)
    }
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

    // Measured line boxes for the two labels the ring is sandwiched between,
    // so `WidgetLayout.ringDiameter` is solving the real vertical budget.
    private let topLabelHeight: CGFloat = 14
    private let bottomLabelHeight: CGFloat = 15
    private let spacing: CGFloat = 8
    private let strokeWidth: CGFloat = 6

    var body: some View {
        // The ring used to be a hardcoded 80pt, which overran the 116pt content
        // box of a 148-class device and clipped the stack at both ends
        // (gh#239 F4). Reading the box the view was actually handed is what
        // keeps that from returning on the next screen size.
        GeometryReader { geo in
            let diameter = WidgetLayout.ringDiameter(
                content: geo.size,
                topLabelHeight: topLabelHeight,
                bottomLabelHeight: bottomLabelHeight,
                spacing: spacing
            )
            content(diameter: diameter)
                .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    @ViewBuilder
    private func content(diameter: CGFloat) -> some View {
        if let event {
            let isCurrent = event.startDate <= entry.date && event.endDate > entry.date
            let total = event.endDate.timeIntervalSince(event.startDate)
            let elapsed = max(0, entry.date.timeIntervalSince(event.startDate))
            let progress = isCurrent ? min(1, elapsed / max(1, total)) : 0
            let remaining = max(0, event.endDate.timeIntervalSince(entry.date))
            let color = snapshotColor(event)

            VStack(spacing: spacing) {
                Text("\(formatTime(event.startDate)) – \(formatTime(event.endDate))")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .widgetFit()

                ZStack {
                    Circle()
                        .stroke(color.opacity(0.2), lineWidth: strokeWidth)
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(color, style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round))
                        .rotationEffect(.degrees(-90))

                    // Constrained to the ring's INNER box, not the widget: the
                    // label is what has to give when "10h 45m left" meets a
                    // small ring, and without a width to shrink against it used
                    // to spill onto the stroke.
                    Group {
                        if isCurrent {
                            Text(LFormat.remaining(seconds: remaining))
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .monospacedDigit()
                        } else {
                            Text(L(.next))
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                        }
                    }
                    .foregroundStyle(.secondary)
                    .widgetFit(0.55)
                    .padding(.horizontal, 2)
                    .frame(width: max(0, diameter - strokeWidth * 2 - 6))
                }
                .frame(width: diameter, height: diameter)

                Text(event.title)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .widgetFit()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: spacing) {
                ZStack {
                    Circle()
                        .stroke(Color.secondary.opacity(0.2), lineWidth: strokeWidth)
                    Text("--")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                .frame(width: diameter, height: diameter)
                Text(L(.noEvents))
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .widgetFit()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
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
            // One packing for the whole entry — see `WidgetLayout.miniTimelineSlots`
            // for why a per-event one put concurrent blocks on top of each other.
            let slots = WidgetLayout.miniTimelineSlots(for: entry.events)

            ZStack(alignment: .topLeading) {
                // Hour grid lines + labels
                ForEach(Array(hours.enumerated()), id: \.offset) { _, hour in
                    let y = nowY + CGFloat(hour.timeIntervalSince(now)) * pps

                    if y > -10 && y < h + 10 {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.2))
                            .frame(width: eventWidth, height: 0.5)
                            .offset(x: eventLeft, y: y)

                        // Suppressed by DISTANCE IN POINTS from the now-label,
                        // not by minutes: the old 20-minute guard was worth
                        // 6.4-7.7pt depending on widget height, under the 8.2pt
                        // a 7pt label occupies, so the two collided (gh#239 F7).
                        if WidgetLayout.hourLabelFits(markerY: y, nowY: nowY) {
                            Text(formatHour(hour, calendar: calendar))
                                .font(.system(size: 7, weight: .semibold, design: .rounded))
                                .foregroundStyle(.secondary)
                                .widgetFit()
                                .frame(width: labelWidth - 2, alignment: .leading)
                                .offset(x: 1, y: y - 5)
                        }
                    }
                }

                // Current time label
                Text(formatTime(now))
                    .font(.system(size: 7, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.primary)
                    .widgetFit()
                    .frame(width: labelWidth - 2, alignment: .leading)
                    .offset(x: 1, y: nowY - 5)

                // Event blocks. Lane citizens first, interrupt overlays on top.
                let gap: CGFloat = 2
                ForEach(Array(entry.events.enumerated()), id: \.offset) { idx, event in
                    let slot = slots[idx]
                    let blockTop = nowY + CGFloat(event.startDate.timeIntervalSince(now)) * pps
                    let blockH = CGFloat(event.endDate.timeIntervalSince(event.startDate)) * pps

                    if !slot.isOverlay, blockTop + blockH > -10, blockTop < h + 10 {
                        let color = snapshotColor(event)
                        let colX = eventLeft + eventWidth * CGFloat(slot.x)
                        let colWidth = eventWidth * CGFloat(slot.width)
                        block(event: event, color: color, style: .lane,
                              width: max(0, colWidth - gap), height: max(4, blockH - 2),
                              blockTop: blockTop)
                            .offset(x: colX, y: blockTop + 1)
                    }
                }

                // Interrupt events: left-indented within their parent's slot
                // (the canvas' leadingInset convention, scaled for the widget).
                ForEach(Array(entry.events.enumerated()), id: \.offset) { idx, event in
                    let slot = slots[idx]
                    let blockTop = nowY + CGFloat(event.startDate.timeIntervalSince(now)) * pps
                    let blockH = CGFloat(event.endDate.timeIntervalSince(event.startDate)) * pps

                    if slot.isOverlay, blockTop + blockH > -10, blockTop < h + 10 {
                        let color = snapshotColor(event)
                        let leadingInset: CGFloat = 4
                        let colX = eventLeft + eventWidth * CGFloat(slot.x)
                        let colWidth = eventWidth * CGFloat(slot.width)
                        block(event: event, color: color, style: .interrupt,
                              width: max(0, colWidth - gap - leadingInset), height: max(4, blockH - 2),
                              blockTop: blockTop)
                            .offset(x: colX + leadingInset, y: blockTop + 1)
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

    /// How one block is drawn. The two passes differ only in these values, so
    /// they are named rather than derived from each other — an interrupt's
    /// heavier border used to be inferred from its stroke width being > 1.
    private struct BlockStyle {
        let cornerRadius: CGFloat
        let strokeWidth: CGFloat
        let strokeOpacity: Double
        let titleTopPad: CGFloat
        let titleSidePad: CGFloat

        /// A lane citizen.
        static let lane = BlockStyle(cornerRadius: 4, strokeWidth: 1, strokeOpacity: 0.7,
                                     titleTopPad: 3, titleSidePad: 4)
        /// An interrupt drawn inside its parent: tighter, and outlined at full
        /// strength so it reads as sitting on top.
        static let interrupt = BlockStyle(cornerRadius: 3, strokeWidth: 1.2, strokeOpacity: 1,
                                          titleTopPad: 2, titleSidePad: 3)
    }

    /// One drawn block, shared by both passes.
    private func block(
        event: SharedEventSnapshot, color: Color, style: BlockStyle,
        width: CGFloat, height: CGFloat, blockTop: CGFloat
    ) -> some View {
        // Keeps the title on screen when the block starts above the viewport.
        let titleInset = max(style.titleTopPad, -blockTop + style.titleTopPad)
        return RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous)
            .fill(color.opacity(0.4))
            .overlay(
                RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous)
                    .stroke(color.opacity(style.strokeOpacity), lineWidth: style.strokeWidth)
            )
            .frame(width: width, height: height)
            .overlay(alignment: .topLeading) {
                if height > 10 {
                    Text(event.title)
                        .font(.system(size: 8, weight: .semibold))
                        .widgetFit()
                        .padding(.horizontal, style.titleSidePad)
                        .padding(.top, titleInset)
                }
            }
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
                // `L(.timeline)` here was the widget's own NAME standing in for
                // a status, while the list widget said "Now" in the same state
                // (gh#239 F10).
                Text(isCurrent ? L(.now) : L(.upNext))
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .widgetFit()

                Text(event.title)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .widgetFit()

                Text(formatTime(entry.date))
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .widgetFit()

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
                        .widgetFit()
                    Spacer(minLength: 4)
                    Text(formatTime(event.endDate))
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .widgetFit()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text(L(.timeline))
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .widgetFit()
                Text(formatTime(entry.date))
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .widgetFit()
                Spacer()
                Text(L(.noEvents))
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .widgetFit()
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
                    .widgetFit()
                Spacer(minLength: 4)
                Text("\(entry.events.count)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .widgetFit()
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
                            .widgetFit()
                    }
                    Text(event.title)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                        .allowsTightening(true)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("\(formatTime(event.startDate)) – \(formatTime(event.endDate))")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .widgetFit()
                }
            } else {
                Text(L(.noMoreEvents))
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .widgetFit()
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

    // Measured against the rendered stack, not guessed: the header's 12pt
    // rounded face occupies a 14.3pt line box, and a row is the 28pt colour bar
    // with its 13pt title and 10pt time line sitting inside it.
    //
    // The 4pt row spacing (was 6) is what buys the third row back on a
    // 116pt-tall content box: at 6pt the same stack rounds down to two rows and
    // leaves 27pt of dead space, which is a worse answer than a tighter rhythm.
    private let headerHeight: CGFloat = 15
    private let rowHeight: CGFloat = 28
    private let rowSpacing: CGFloat = 4

    var body: some View {
        // `prefix(4)` needed ~157pt against content boxes of 116-138pt, so on
        // EVERY device size a four-event day lost the date header off the top
        // and the last row off the bottom (gh#239 F2). The count now comes from
        // the height the view was handed.
        GeometryReader { geo in
            let capacity = WidgetLayout.listRowCapacity(
                contentHeight: geo.size.height,
                headerHeight: headerHeight,
                rowHeight: rowHeight,
                spacing: rowSpacing
            )
            content(capacity: capacity)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private func content(capacity: Int) -> some View {
        VStack(alignment: .leading, spacing: rowSpacing) {
            HStack {
                Text(dayString)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .widgetFit()
                Spacer(minLength: 4)
                // The header carries the day's TOTAL, so a day the list had to
                // trim still says how much it is not showing.
                Text(LFormat.eventCount(entry.events.count))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .widgetFit()
            }

            if entry.events.isEmpty {
                Spacer()
                Text(L(.noEventsToday))
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .widgetFit()
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer()
            } else {
                ForEach(Array(entry.events.prefix(capacity).enumerated()), id: \.element.id) { _, event in
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(snapshotColor(event))
                            .frame(width: 3, height: rowHeight)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(event.title)
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .strikethrough(event.isDone)
                                .foregroundStyle(event.isDone ? .secondary : .primary)
                                .widgetFit()
                            Text(shortTimeString(event))
                                .font(.system(size: 10, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                                .widgetFit()
                        }

                        Spacer(minLength: 0)

                        if event.startDate <= entry.date && event.endDate > entry.date && !event.isDone {
                            Text(L(.now).uppercased())
                                .font(.system(size: 9, weight: .bold, design: .rounded))
                                .widgetFit()
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(snapshotColor(event).opacity(0.2), in: Capsule())
                        }
                    }
                    .frame(height: rowHeight)
                }
                Spacer(minLength: 0)
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
        if event.isAllDay { return L(.allDay) }
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
