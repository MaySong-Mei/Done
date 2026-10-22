import WidgetKit
import SwiftUI

// MARK: - Shared Entry & Provider

struct DoneWidgetEntry: TimelineEntry {
    let date: Date
    /// The civil day's occurrences: what the ring, bar and lists show.
    let events: [SharedEventSnapshot]
    /// The occurrences overlapping the mini timeline's window, which can reach
    /// into yesterday or tomorrow (see `WidgetLayout.miniWindow`).
    let windowEvents: [SharedEventSnapshot]
}

struct DoneWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> DoneWidgetEntry {
        DoneWidgetEntry(date: .now, events: Self.sampleEvents, windowEvents: Self.sampleEvents)
    }

    func getSnapshot(in context: Context, completion: @escaping (DoneWidgetEntry) -> Void) {
        completion(Self.entry(at: .now, from: SharedWidgetData.read(), calendar: .current))
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
            .map { date in Self.entry(at: date, from: all, calendar: calendar) }
        completion(Timeline(entries: entries, policy: .atEnd))
    }

    private static func entry(
        at date: Date, from all: [SharedEventSnapshot], calendar: Calendar
    ) -> DoneWidgetEntry {
        DoneWidgetEntry(
            date: date,
            events: WidgetTimelineSchedule.events(visibleOn: date, from: all, calendar: calendar),
            windowEvents: WidgetTimelineSchedule.events(
                overlapping: WidgetLayout.miniWindow(now: date), from: all
            )
        )
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
    /// The 0.7 default is the floor at which the rounded 10-13pt faces stay
    /// legible at arm's length; below that truncation is the kinder failure.
    ///
    /// **Pass a higher floor for the sub-10pt faces.** Applying 0.7 to the mini
    /// timeline's 8pt block titles drew them at 5.6pt — and, in the multi-column
    /// day this widget exists to lay out, they still truncated, so the scaling
    /// bought nothing and cost every remaining pixel of legibility (gh#239 QA).
    /// A label that cannot fit at a readable size should truncate at a readable
    /// size.
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

    private let topLabelHeight = WidgetLayout.Metrics.ringTopLabelHeight
    private let bottomLabelHeight = WidgetLayout.Metrics.ringBottomLabelHeight
    private let spacing = WidgetLayout.Metrics.ringSpacing
    private let strokeWidth = WidgetLayout.Metrics.ringStrokeWidth

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
                spacing: spacing,
                maximum: WidgetLayout.Metrics.ringMaxDiameter
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
                    // label is what has to give when the longest remaining-string
                    // meets a small ring, and without a width to shrink against
                    // it used to spill onto the stroke.
                    //
                    // TWO lines, not one. At one line the longest reachable
                    // Chinese string ("还剩10时45分") needed 0.53 of 13pt on a
                    // 148-class ring — under the floor, so it truncated, and at
                    // the floor it would have drawn at 7.4pt (gh#239 QA). Wrapped,
                    // it stays over the floor. The ring's diameter is solved
                    // from the box now, so a second line costs the stack nothing.
                    // The break is the string's own, not the line breaker's —
                    // see `LFormat.remaining(seconds:twoLines:)`.
                    //
                    // The 12pt inset keeps the label's corners inside the circle:
                    // a two-line block half as tall as it is wide has its corner
                    // at the largest radius, and at this width that corner clears
                    // the inner stroke edge.
                    Group {
                        if isCurrent {
                            Text(LFormat.remaining(seconds: remaining, twoLines: true))
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .monospacedDigit()
                        } else {
                            Text(L(.next))
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                        }
                    }
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.6)
                    .allowsTightening(true)
                    .frame(width: max(0, diameter - strokeWidth * 2 - 12))
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
                Text(LFormat.idleStatus(dayHasEvents: !entry.events.isEmpty))
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
    @Environment(\.legibilityWeight) private var legibilityWeight

    /// The lane's coordinates, shared by the axis and both block passes.
    private struct Lane {
        let height: CGFloat
        let nowY: CGFloat
        let pointsPerSecond: CGFloat
        let now: Date
        let left: CGFloat
        let width: CGFloat

        func y(_ date: Date) -> CGFloat {
            nowY + CGFloat(date.timeIntervalSince(now)) * pointsPerSecond
        }
    }

    var body: some View {
        GeometryReader { geo in
            let calendar = Calendar.current
            let window = WidgetLayout.miniWindow(now: entry.date)
            let labelWidth: CGFloat = 36
            let lane = Lane(
                height: geo.size.height,
                nowY: geo.size.height * CGFloat(WidgetLayout.Metrics.miniNowFraction),
                pointsPerSecond: geo.size.height / CGFloat(window.duration),
                now: entry.date,
                left: labelWidth,
                width: geo.size.width - labelWidth - 4
            )

            let hours = hourMarkers(from: window.start, to: window.end, calendar: calendar)
            // The occurrences overlapping the window, not the civil day's (see
            // `WidgetLayout.miniWindow`). One packing for all of them — see
            // `WidgetLayout.miniTimelineSlots` for why a per-event one put
            // concurrent blocks on top of each other.
            let events = entry.windowEvents
            let slots = WidgetLayout.miniTimelineSlots(for: events, window: window)
            let nextStarts = WidgetLayout.miniNextStarts(for: events, slots: slots, window: window)
            let placed = placeBlocks(events: events, slots: slots, nextStarts: nextStarts,
                                     window: window, lane: lane)

            ZStack(alignment: .topLeading) {
                // Hour grid lines + labels
                ForEach(Array(hours.enumerated()), id: \.offset) { _, hour in
                    let y = lane.y(hour)

                    if y > -10 && y < lane.height + 10 {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.2))
                            .frame(width: lane.width, height: 0.5)
                            .offset(x: lane.left, y: y)

                        // Suppressed by DISTANCE IN POINTS from the now-label,
                        // not by minutes: the old 20-minute guard was worth
                        // 6.4-7.7pt depending on widget height, under the 8.2pt
                        // a 7pt label occupies, so the two collided (gh#239 F7).
                        // And drawn whole or not at all at the lane's edges.
                        if WidgetLayout.hourLabelFits(markerY: y, nowY: lane.nowY),
                           WidgetLayout.hourLabelInsideBox(markerY: y, contentHeight: lane.height) {
                            Text(formatHour(hour, calendar: calendar))
                                .font(.system(size: 7, weight: .semibold, design: .rounded))
                                .foregroundStyle(.secondary)
                                .widgetFit(1)
                                .frame(width: labelWidth - 2, alignment: .leading)
                                .offset(x: 1, y: y - WidgetLayout.axisLabelRise)
                        }
                    }
                }

                // Current time label
                Text(formatTime(entry.date))
                    .font(.system(size: 7, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.primary)
                    .widgetFit(1)
                    .frame(width: labelWidth - 2, alignment: .leading)
                    .offset(x: 1, y: lane.nowY - WidgetLayout.axisLabelRise)

                // Event blocks. Lane citizens first, interrupt overlays on top.
                ForEach(Array(events.enumerated()), id: \.offset) { idx, event in
                    if !slots[idx].isOverlay, let place = placed[idx] {
                        block(event: event, place: place)
                    }
                }

                // Interrupt events: left-indented within their parent's slot
                // (the canvas' leadingInset convention, scaled for the widget).
                ForEach(Array(events.enumerated()), id: \.offset) { idx, event in
                    if slots[idx].isOverlay, let place = placed[idx] {
                        block(event: event, place: place)
                    }
                }

                // Now indicator — above the blocks, as on the canvas. Block
                // titles are placed clear of it (`WidgetLayout.miniTitlePlacement`),
                // and where one cannot be, the line is cut behind it.
                let dot = WidgetLayout.Metrics.miniNowDotRadius
                Circle()
                    .fill(Color.primary)
                    .frame(width: 2 * dot, height: 2 * dot)
                    .offset(x: lane.left - dot, y: lane.nowY - dot)
                ZStack(alignment: .topLeading) {
                    Rectangle()
                        .fill(Color.primary)
                        .frame(width: lane.width + 4, height: 1)
                        .offset(x: lane.left, y: lane.nowY - 0.5)
                    ForEach(Array(events.enumerated()), id: \.offset) { idx, event in
                        if let place = placed[idx], let title = place.title, title.knocksOutNowLine {
                            // The title's own frame, laid out as the block lays
                            // it out, a point wider all round. White, not black:
                            // only its alpha cuts, and a rendering mode that
                            // turns luminance into alpha keeps white opaque.
                            titleText(title.run)
                                .hidden()
                                .background(Rectangle().fill(Color.white).padding(-1))
                                .padding(.leading, title.pads.leading)
                                .frame(width: place.width, alignment: .leading)
                                .offset(x: place.x, y: title.top)
                                .blendMode(.destinationOut)
                        }
                    }
                }
                // The knockout is confined to the line's own layer, which
                // spans the lane so nothing in it is drawn outside its bounds.
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                .compositingGroup()
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
        let leadingInset: CGFloat

        /// A lane citizen.
        static let lane = BlockStyle(cornerRadius: 4, strokeWidth: 1, strokeOpacity: 0.7,
                                     titleTopPad: 3, titleSidePad: 4, leadingInset: 0)
        /// An interrupt drawn inside its parent: tighter, and outlined at full
        /// strength so it reads as sitting on top.
        static let interrupt = BlockStyle(cornerRadius: 3, strokeWidth: 1.2, strokeOpacity: 1,
                                          titleTopPad: 2, titleSidePad: 3, leadingInset: 4)
    }

    /// One block's place in the lane, in the lane's coordinates.
    private struct PlacedBlock {
        let style: BlockStyle
        let x: CGFloat
        let rectTop: CGFloat
        let width: CGFloat
        let height: CGFloat
        let title: PlacedTitle?
    }

    /// A block's title: what it draws, its line box's top in the lane's
    /// coordinates, and its padding.
    private struct PlacedTitle {
        let run: WidgetLayout.MiniTitleRun
        let top: CGFloat
        let pads: WidgetLayout.MiniTitlePads
        let knocksOutNowLine: Bool
    }

    /// Every shown block's place, `nil` for the rest.
    ///
    /// A rectangle starts 1pt below its block's start and is drawn at
    /// `WidgetLayout.miniDrawnHeight`, which keeps a floored short block out of
    /// the one after it. The rectangles come first because a lane block's
    /// title must know where the interrupts drawn over it go: the title goes
    /// where `WidgetLayout.miniTitlePlacement` finds room for its ink clear of
    /// them and of the now line and its text fits, or nowhere. A zero-length
    /// interrupt that would hide a sibling is left out
    /// (`WidgetLayout.miniCoincidingOverlays`).
    private func placeBlocks(
        events: [SharedEventSnapshot], slots: [WidgetLayout.Slot], nextStarts: [Date?],
        window: DateInterval, lane: Lane
    ) -> [PlacedBlock?] {
        let gap: CGFloat = 2
        var rects = events.indices.map { idx -> (style: BlockStyle, top: CGFloat, height: CGFloat)? in
            let event = events[idx]
            guard WidgetLayout.miniWindowShows(event, in: window) else { return nil }
            let blockTop = lane.y(event.startDate)
            let span = CGFloat(event.endDate.timeIntervalSince(event.startDate)) * lane.pointsPerSecond
            let height = WidgetLayout.miniDrawnHeight(
                span: span, roomBelow: nextStarts[idx].map { lane.y($0) - blockTop }
            )
            return (slots[idx].isOverlay ? BlockStyle.interrupt : BlockStyle.lane, blockTop + 1, height)
        }
        let parents = WidgetLayout.miniOverlayParents(for: events)
        let drawn = rects.map { rect in rect.map { WidgetLayout.MiniBand(top: $0.top, bottom: $0.top + $0.height) } }
        for idx in WidgetLayout.miniCoincidingOverlays(for: events, parents: parents, rects: drawn) {
            rects[idx] = nil
        }
        let extents = rects.map { rect in
            rect.map { WidgetLayout.miniDrawnExtent(top: $0.top, height: $0.height, strokeWidth: $0.style.strokeWidth) }
        }
        return events.indices.map { idx -> PlacedBlock? in
            guard let rect = rects[idx] else { return nil }
            let x = lane.left + lane.width * CGFloat(slots[idx].x) + rect.style.leadingInset
            let width = max(0, lane.width * CGFloat(slots[idx].width) - gap - rect.style.leadingInset)
            let placed = WidgetLayout.miniTitlePlacement(
                rectTop: rect.top, rectBottom: rect.top + rect.height, contentHeight: lane.height,
                nowY: lane.nowY, topPad: rect.style.titleTopPad,
                covers: WidgetLayout.miniCovers(of: idx, parents: parents, extents: extents)
            ) { title -> PlacedTitle? in
                let pads = WidgetLayout.miniTitlePads(
                    blockX: x, blockWidth: width, standard: rect.style.titleSidePad, title: title,
                    laneLeft: lane.left, nowY: lane.nowY
                )
                guard let run = WidgetLayout.miniTitleRun(
                    events[idx].title, width: width - pads.leading - pads.trailing, size: title.size,
                    bold: legibilityWeight == .bold
                ) else { return nil }
                return PlacedTitle(run: run, top: WidgetLayout.miniTitleRunTop(title, run: run), pads: pads,
                                   knocksOutNowLine: title.knocksOutNowLine)
            }
            return PlacedBlock(
                style: rect.style, x: x, rectTop: rect.top, width: width, height: rect.height, title: placed?.drawn
            )
        }
    }

    /// One drawn block at its place.
    private func block(event: SharedEventSnapshot, place: PlacedBlock) -> some View {
        let color = snapshotColor(event)
        return RoundedRectangle(cornerRadius: place.style.cornerRadius, style: .continuous)
            .fill(color.opacity(0.4))
            .overlay(
                RoundedRectangle(cornerRadius: place.style.cornerRadius, style: .continuous)
                    .stroke(color.opacity(place.style.strokeOpacity), lineWidth: place.style.strokeWidth)
            )
            .frame(width: place.width, height: place.height)
            .overlay(alignment: .topLeading) {
                if let title = place.title {
                    titleText(title.run)
                        .padding(.leading, title.pads.leading)
                        .offset(y: title.top - place.rectTop)
                }
            }
            .offset(x: place.x, y: place.rectTop)
    }

    /// A block's title, shared by the block and the now line's knockout so the
    /// two lay out the same. Cut and sized by `WidgetLayout.miniTitleRun`, and
    /// drawn at its own size whatever the block offers: SwiftUI's own fitting
    /// is what drew a bare "…".
    private func titleText(_ run: WidgetLayout.MiniTitleRun) -> some View {
        let text = Text(run.text).font(.system(size: run.size, weight: .semibold))
        // Kerning only when tightened: a kerning of 0 switches the font's own
        // pair kerning off, and the run was measured with it on.
        return (run.kerning == 0 ? text : text.kerning(run.kerning))
            .lineLimit(1)
            .fixedSize()
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
    @Environment(\.legibilityWeight) private var legibilityWeight

    private var event: SharedEventSnapshot? {
        currentEvent(in: entry) ?? nextUpEvent(in: entry)
    }

    var body: some View {
        // The bar was the small view gh#239 F4 left out: only the ring got a
        // box-solved dimension, and the bar's fixed stack cleared a 148-class
        // content box by under a point — and failed to clear it at all with the
        // 12h clock, where the descender of "pm" landed 1.0pt past the bottom
        // edge (gh#239 QA). Solving its clock line from the box gives it the
        // same guarantee the ring has, and something a test can pin.
        GeometryReader { geo in
            let lines = WidgetLayout.barTitleLines(
                contentHeight: geo.size.height, contentWidth: geo.size.width, title: event?.title ?? "",
                bold: legibilityWeight == .bold
            )
            content(clockHeight: WidgetLayout.barClockHeight(contentHeight: geo.size.height, titleLines: lines),
                    titleLines: lines)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private func content(clockHeight: CGFloat, titleLines: Int) -> some View {
        let spacing = WidgetLayout.barSpacing(titleLines: titleLines)
        if let event {
            let isCurrent = event.startDate <= entry.date && event.endDate > entry.date
            let total = event.endDate.timeIntervalSince(event.startDate)
            let elapsed = max(0, entry.date.timeIntervalSince(event.startDate))
            let progress = isCurrent ? min(1, elapsed / max(1, total)) : 0

            // Two groups around one spacer, so the stack has exactly the four
            // gaps `WidgetLayout.barStackHeight` sums: a lone spacer between
            // the clock and the track took a gap on BOTH sides (gh#239 sim QA).
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: spacing) {
                    // `L(.timeline)` here was the widget's own NAME standing in for
                    // a status, while the list widget said "Now" in the same state
                    // (gh#239 F10).
                    Text(isCurrent ? L(.now) : L(.upNext))
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .widgetFit()

                    // Two lines where it needs them and the box has room
                    // for the second (`WidgetLayout.barTitleLines`), one
                    // elsewhere (gh#248).
                    Text(event.title)
                        .font(.system(size: WidgetLayout.Metrics.barSubtitleFontSize, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(titleLines)
                        .minimumScaleFactor(0.7)
                        .allowsTightening(true)

                    // The clock while the event runs, where the track and thumb
                    // give it meaning; its START while it is up next — the current
                    // time under "Up Next" read as when it begins (gh#239 sim QA).
                    Text(formatTime(isCurrent ? entry.date : event.startDate))
                        .font(.system(size: WidgetLayout.Metrics.barClockFontSize, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .widgetFit()
                        .frame(height: clockHeight)
                }

                Spacer(minLength: spacing)

                VStack(alignment: .leading, spacing: spacing) {
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
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            VStack(alignment: .leading, spacing: WidgetLayout.Metrics.barSpacing) {
                // A status, as in the event branch: `L(.timeline)` here was the
                // widget's own name, the misuse F10 fixed only over there.
                Text(LFormat.idleStatus(dayHasEvents: !entry.events.isEmpty))
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .widgetFit()
                Text(formatTime(entry.date))
                    .font(.system(size: WidgetLayout.Metrics.barClockFontSize, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .widgetFit()
                    .frame(height: clockHeight)
                Spacer(minLength: 0)
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
    /// The reader's text size, as a factor on every size below, capped by
    /// `DoneWidgetEntryView` (gh#248). Scaled from a base of 100: a scaled
    /// value is rounded to the pixel grid, so a base of 1 came out at 1 on the
    /// SE's 2x screen at xxLarge, and at 4/3 on a 3x one (gh#248 sim QA).
    @ScaledMetric(relativeTo: .body) private var textSize: CGFloat = 100
    private var scale: CGFloat { textSize / 100 }

    private var event: SharedEventSnapshot? {
        currentEvent(in: entry) ?? nextUpEvent(in: entry)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6 * scale) {
            HStack {
                Text(dayString)
                    .font(.system(size: 12 * scale, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .widgetFit()
                Spacer(minLength: 4)
                Text("\(entry.events.count)")
                    .font(.system(size: 11 * scale, weight: .bold, design: .rounded))
                    .widgetFit()
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.1), in: Capsule())
            }

            if let event {
                // The card, and under it as many of the events after it as fit:
                // the card stood alone at the foot of the box with a band of
                // nothing over it (gh#248).
                // No spacer after it: as a third child of the stack it took a
                // gap of its own, and the rows were offered that much less
                // than the box had (gh#248 sim QA). The frame below keeps the
                // stack at the top. At the largest text sizes the SE's box
                // holds the card only with its title on one line.
                let following = WidgetLayout.smallListFollowing(entry.events, card: event, now: entry.date)
                ViewThatFits(in: .vertical) {
                    cardAndRows(event, following, rows: 3)
                    cardAndRows(event, following, rows: 2)
                    cardAndRows(event, following, rows: 1)
                    cardAndRows(event, following, rows: 0)
                    cardAndRows(event, following, rows: 0, titleLines: 1)
                }
            } else {
                Spacer(minLength: 0)
                Text(LFormat.idleStatus(dayHasEvents: !entry.events.isEmpty))
                    .font(.system(size: 14 * scale, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .widgetFit()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func cardAndRows(
        _ event: SharedEventSnapshot, _ following: [SharedEventSnapshot], rows: Int, titleLines: Int = 2
    ) -> some View {
        let shown = Array(following.prefix(min(rows, WidgetLayout.Metrics.smallListRowCap)))
        return VStack(alignment: .leading, spacing: 6 * scale) {
            card(event, titleLines: titleLines)
            if !shown.isEmpty {
                VStack(alignment: .leading, spacing: 3 * scale) {
                    ForEach(shown, id: \.id) { row($0) }
                }
            }
        }
    }

    private func card(_ event: SharedEventSnapshot, titleLines: Int) -> some View {
        let isCurrent = event.startDate <= entry.date && event.endDate > entry.date
        return VStack(alignment: .leading, spacing: 4 * scale) {
            HStack(spacing: 4) {
                Circle()
                    .fill(snapshotColor(event))
                    .frame(width: 6, height: 6)
                Text(isCurrent ? L(.now) : L(.next))
                    .font(.system(size: 10 * scale, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .widgetFit()
            }
            Text(event.title)
                .font(.system(size: 15 * scale, weight: .semibold, design: .rounded))
                .lineLimit(titleLines)
                .minimumScaleFactor(0.7)
                .allowsTightening(true)
                .fixedSize(horizontal: false, vertical: true)
            Text("\(formatTime(event.startDate)) – \(formatTime(event.endDate))")
                .font(.system(size: 11 * scale, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .widgetFit()
        }
    }

    private func row(_ event: SharedEventSnapshot) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(snapshotColor(event))
                .frame(width: 3, height: 12 * scale)
            // The title takes the row's spare width, a spacer beside it kept
            // some for itself and cut the title early (gh#248 review).
            Text(event.title)
                .font(.system(size: 12 * scale, weight: .semibold, design: .rounded))
                .widgetFit()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 4)
            Text(rowTime(event))
                .font(.system(size: 10 * scale, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .widgetFit()
        }
    }

    /// All-day events never reach the widget's list (`WidgetTimelineSchedule`
    /// leaves them out), so a row is running or upcoming.
    private func rowTime(_ event: SharedEventSnapshot) -> String {
        event.startDate <= entry.date ? L(.now) : formatTime(event.startDate)
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

    // Single-sourced with the arithmetic that consumes them. These used to be
    // literals here AND literals again in `WidgetLayoutTests`, so raising the
    // row height in this file reintroduced the F2 clipping with the whole suite
    // green (gh#239 QA).
    // The reader's text size, as a factor on every size below and on the
    // heights the row count is solved from, capped by `DoneWidgetEntryView`
    // (gh#248), through `WidgetLayout.listHeights`. Scaled from a base of 100,
    // as the small list's is, so pixel rounding cannot swallow it.
    @ScaledMetric(relativeTo: .body) private var textSize: CGFloat = 100
    private var scale: CGFloat { textSize / 100 }
    private var headerHeight: CGFloat { WidgetLayout.listHeights(scale: scale).header }
    private var rowHeight: CGFloat { WidgetLayout.listHeights(scale: scale).row }
    private let rowSpacing = WidgetLayout.Metrics.listRowSpacing

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
                spacing: rowSpacing,
                cap: WidgetLayout.Metrics.listRowCap
            )
            content(capacity: capacity)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private func content(capacity: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(dayString)
                    .font(.system(size: 12 * scale, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .widgetFit()
                Spacer(minLength: 4)
                // The header carries the day's TOTAL, so a day the list had to
                // trim still says how much it is not showing.
                Text(LFormat.eventCount(entry.events.count))
                    .font(.system(size: 11 * scale, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .widgetFit()
            }
            // Pinned, so the header drawn IS the height `listRowCapacity`
            // subtracts.
            .frame(height: headerHeight)

            if entry.events.isEmpty {
                Spacer()
                Text(L(.noEventsToday))
                    .font(.system(size: 14 * scale, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .widgetFit()
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer()
            } else {
                // Anchored on `entry.date`, not on the head of the day: a
                // plain `prefix` showed the morning's finished rows and dropped
                // the running one (gh#239 QA).
                let rows = WidgetLayout.listWindow(entry.events, now: entry.date, capacity: capacity)
                // Spacing before every row and none after the last: the stack
                // `listRowCapacity` models.
                VStack(alignment: .leading, spacing: rowSpacing) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { _, event in
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(snapshotColor(event))
                                .frame(width: 3, height: rowHeight)

                            VStack(alignment: .leading, spacing: 1) {
                                Text(event.title)
                                    .font(.system(size: 13 * scale, weight: .semibold, design: .rounded))
                                    .strikethrough(event.isDone)
                                    .foregroundStyle(event.isDone ? .secondary : .primary)
                                    .widgetFit()
                                Text(shortTimeString(event))
                                    .font(.system(size: 10 * scale, weight: .medium, design: .rounded))
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                                    .widgetFit()
                            }

                            Spacer(minLength: 0)

                            if event.startDate <= entry.date && event.endDate > entry.date && !event.isDone {
                                Text(L(.now).uppercased())
                                    .font(.system(size: 9 * scale, weight: .bold, design: .rounded))
                                    .widgetFit(0.85)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(snapshotColor(event).opacity(0.2), in: Capsule())
                            }
                        }
                        .frame(height: rowHeight)
                    }
                }
                .padding(.top, rowSpacing)
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
        .configurationDisplayName(L(.todaysEvents))
        .description(L(.doneWidgetDesc))
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
    }
}

struct DoneWidgetEntryView: View {
    @Environment(\.widgetFamily) var family
    @Environment(\.widgetContentMargins) private var margins
    let entry: DoneWidgetEntry

    var body: some View {
        // The system's margins, applied here because the configuration turns
        // them off — for the medium list's top and bottom, which draws in its
        // own (`WidgetLayout.Metrics.listVerticalMargin`).
        //
        // The lists follow the reader's text size up to two steps over the
        // default; past that the small list's card no longer fits the SE's
        // box (gh#248). The other faces keep their sizes: their layouts are
        // solved for them.
        switch family {
        case .systemSmall:
            DoneWidgetSmallView(entry: entry)
                .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                .padding(margins)
        default:
            DoneWidgetMediumView(entry: entry)
                .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                .padding(.leading, margins.leading)
                .padding(.trailing, margins.trailing)
                .padding(.vertical, min(margins.top, margins.bottom, WidgetLayout.Metrics.listVerticalMargin))
        }
    }
}
