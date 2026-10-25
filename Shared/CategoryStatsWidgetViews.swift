import SwiftUI
import WidgetKit

/// The faces of the "Time by Category" widget, one per supported family.
enum CategoryStatsFace: CaseIterable {
    case small
    case medium
    case large
    case rectangular
    case circular

    /// The face a widget family draws. Here rather than in the widget's
    /// view, so `DoneTests` can see the mapping.
    init(family: WidgetFamily) {
        switch family {
        case .accessoryCircular: self = .circular
        case .accessoryRectangular: self = .rectangular
        case .systemMedium: self = .medium
        case .systemLarge: self = .large
        default: self = .small
        }
    }
}

/// Layout numbers and pure helpers for the category-stats faces.
///
/// The faces live in this file, which both targets compile, rather than in
/// `DoneWidget/`: the widget target has no test bundle, and these faces'
/// one hard requirement — nothing drawn outside the content box, in either
/// language, with Bold Text on or off — is something `DoneTests` can render
/// and count (`CategoryStatsRenderTests`). The widget only picks the face
/// for its family and rendering mode.
///
/// Type is set at fixed sizes, like the ring's and the bar's: only the list
/// widgets follow the reader's text size. Every face offers fewer rows when
/// the box cannot hold them (`ViewThatFits`), so a heavier face or a taller
/// script loses a row instead of drawing past the edge.
enum CategoryStatsLayout {
    /// The most rows a face lists; the small face as many as the preview
    /// the user picked (`CategoryStatsRenderTests` counts the rows each face
    /// keeps in each box).
    static func rowCap(_ face: CategoryStatsFace) -> Int {
        switch face {
        case .small: return 4
        case .medium: return 5
        case .large: return 10
        case .rectangular: return 2
        case .circular: return 1
        }
    }

    /// How many categories the bar splits into before the rest share one
    /// segment: as many as the face lists, plus the rest, on the lock screen.
    /// Without colour no more than five, the opacity ladder's rungs: past
    /// them a segment is too faint to stand out from the track
    /// (`CategoryStatsRenderTests.testEveryLoggedSegmentStandsOutFromTheTrack`),
    /// so the large face's bar ranks four and the rest while its list goes on.
    static func barCap(_ face: CategoryStatsFace, accented: Bool) -> Int {
        let cap = face == .rectangular ? 3 : rowCap(face)
        return accented ? min(cap, 5) : cap
    }

    static func headerSize(_ face: CategoryStatsFace) -> CGFloat { face == .large ? 15 : 12 }
    static func messageSize(_ face: CategoryStatsFace) -> CGFloat { face == .large ? 15 : 13 }

    static func rowSize(_ face: CategoryStatsFace) -> CGFloat {
        switch face {
        case .small: return 13
        case .large: return 14
        default: return 12
        }
    }

    static func barHeight(_ face: CategoryStatsFace) -> CGFloat {
        switch face {
        case .rectangular: return 5
        case .large: return 12
        default: return 8
        }
    }

    /// The medium and large faces give each row its hours as well as its
    /// share: they have the width.
    static func showsHours(_ face: CategoryStatsFace) -> Bool { face == .medium || face == .large }
    /// The medium and lock-screen faces set their rows closer, so a full
    /// list fits their smallest boxes (`CategoryStatsRenderTests` counts the
    /// rows).
    static func headerToBar(_ face: CategoryStatsFace) -> CGFloat {
        switch face {
        case .medium: return 5
        case .large: return 8
        case .rectangular: return 2
        default: return 6
        }
    }

    static func barToRows(_ face: CategoryStatsFace) -> CGFloat {
        switch face {
        case .medium: return 6
        case .large: return 12
        case .rectangular: return 3
        default: return 8
        }
    }

    static func rowSpacing(_ face: CategoryStatsFace) -> CGFloat {
        switch face {
        case .medium: return 2
        case .large: return 8
        case .rectangular: return 0
        default: return 4
        }
    }
    static let dotSize: CGFloat = 7
    /// The unlogged row's marker is a short bar of the track rather than a
    /// dot: a shape neither a category's dot nor the remainder's ring has.
    static let unloggedMarkerHeight: CGFloat = 3
    static let minimumSegment: CGFloat = 2
    /// The bar's track: what an empty bar shows, and in the elapsed basis
    /// the unlogged part of the span.
    static let trackOpacity = 0.2

    /// Without colour (tinted home screen, lock screen) segments are told
    /// apart by a gap and by opacity, which falls with rank. Every rung an
    /// elapsed bar can set beside the unlogged track stands out from it
    /// (`CategoryStatsRenderTests.testEveryLoggedSegmentStandsOutFromTheTrack`).
    static func barGap(accented: Bool) -> CGFloat { accented ? 2 : 1 }

    static func accentedOpacity(rank: Int) -> Double {
        let ladder = [1.0, 0.72, 0.52, 0.44, 0.3]
        return ladder[min(max(rank, 0), ladder.count - 1)]
    }

    /// The remainder takes the rung after the categories ranked ahead of it:
    /// fainter than each of them, never down at the track.
    static func remainderAccentedOpacity(after ranked: Int) -> Double {
        accentedOpacity(rank: ranked)
    }

    /// In full colour the remainder is a grey of its own, given as its white
    /// level. A category whose colour nobody picked is grey as well — "Other",
    /// the bucket for time with no type, and any type made without choosing
    /// one take `EventTypeTemplateStore.fallbackColorHex`, a mid grey — and
    /// can sit right beside the remainder, so the remainder keeps well to one
    /// side of it: darker in the light scheme, lighter in the dark, and
    /// opaque, so the widget's background cannot move it
    /// (`CategoryStatsRenderTests.testTheRemainderStandsApartFromTheDefaultGrey`;
    /// against the track, `.testEveryLoggedSegmentStandsOutFromTheTrack`).
    static func remainderWhite(dark: Bool) -> Double { dark ? 0.84 : 0.3 }

    /// The circular face's category: the leader, with its share of the
    /// active basis. In the elapsed basis the unlogged time is counted among
    /// the rows, so room for two keeps the leader. `nil` when nothing leads.
    static func ringLeader(_ summary: CategoryStatsSummary) -> CategoryStatsRow? {
        guard summary.status == .ok else { return nil }
        return CategoryStats.breakdown(summary.categories, maxRows: summary.unloggedHours == nil ? 1 : 2,
                                       includeRemainder: false, unlogged: summary.unloggedHours)
            .first { !$0.isUnlogged }
    }

    /// Segment widths for `shares` across `width`, `gap` apart: every
    /// segment at least `minimum` wide when they all fit at that, the rest
    /// split by share. Always sums with the gaps to exactly `width` (when
    /// there is anything to split), so the bar never runs past its frame.
    static func segmentWidths(_ shares: [Double], width: CGFloat, gap: CGFloat, minimum: CGFloat) -> [CGFloat] {
        guard !shares.isEmpty, width > 0 else { return shares.map { _ in 0 } }
        let clean = shares.map { $0.isFinite ? max(0, $0) : 0 }
        let total = clean.reduce(0, +)
        let available = max(0, width - gap * CGFloat(shares.count - 1))
        guard total > 0 else { return shares.map { _ in 0 } }
        let floor = CGFloat(shares.count) * minimum <= available ? minimum : 0
        let spare = available - floor * CGFloat(shares.count)
        return clean.map { floor + spare * CGFloat($0 / total) }
    }

    /// "#RRGGBB" or "#RRGGBBAA" as 0...1 components.
    static func rgba(hex: String) -> (red: Double, green: Double, blue: Double, alpha: Double)? {
        let digits = hex.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
        guard digits.count == 6 || digits.count == 8, let value = UInt64(digits, radix: 16) else { return nil }
        let wide = digits.count == 8
        let shift: UInt64 = wide ? 8 : 0
        return (Double((value >> (16 + shift)) & 0xFF) / 255, Double((value >> (8 + shift)) & 0xFF) / 255,
                Double((value >> shift) & 0xFF) / 255, wide ? Double(value & 0xFF) / 255 : 1)
    }

    /// What the gallery and the placeholder show: the week is the preview
    /// the user picked; the day and the month keep its split at their own
    /// scale, each inside the time its period has had
    /// (`CategoryStatsRenderTests` reads them back). `extended` adds four
    /// smaller categories after the six, so the large face's preview fills
    /// its list.
    static func sample(
        _ period: CategoryStatsPeriod, basis: CategoryStatsBasis = .logged, chinese: Bool, extended: Bool = false
    ) -> CategoryStatsSummary {
        var names = chinese
            ? ["深度工作", "会议", "运动", "阅读", "家务", "杂事"]
            : ["Deep Work", "Meetings", "Exercise", "Reading", "Chores", "Errands"]
        var colors = ["#5E5CE6", "#FF9F0A", "#30D158", "#0A84FF", "#BF5AF2", "#64D2FF"]
        var hours: [Double]
        let more: [Double]
        let elapsed: Double
        switch period {
        case .today:
            hours = [2.5, 1.5, 0.6, 0.6, 0.5, 0.3]
            more = [0.25, 0.2, 0.15, 0.1]
            elapsed = 14
        case .week:
            hours = [13.6, 8.1, 3.3, 3, 2.5, 2]
            more = [1.8, 1.5, 1.2, 0.9]
            elapsed = 62
        case .month:
            hours = [49.5, 29.5, 12, 11, 9, 7.5]
            more = [6, 5, 4, 3]
            elapsed = 21 * 24
        }
        if extended {
            names += chinese ? ["通勤", "社交", "学习", "做饭"] : ["Commute", "Friends", "Study", "Cooking"]
            colors += ["#FF375F", "#FFD60A", "#AC8E68", "#66D4CF"]
            hours += more
        }
        let categories = zip(zip(names, colors), hours)
            .map { CategoryHours(name: $0.0, colorHex: $0.1, hours: $1) }
            .sorted { $0.hours > $1.hours }
        return CategoryStatsSummary(period: period, basis: basis, status: .ok, categories: categories,
                                    totalHours: hours.reduce(0, +), elapsedHours: basis == .elapsed ? elapsed : 0)
    }
}

/// One face of the widget for one entry. `accented` is the widget's
/// rendering mode being anything but full colour.
struct CategoryStatsWidgetView: View {
    let summary: CategoryStatsSummary
    let face: CategoryStatsFace
    let accented: Bool

    var body: some View {
        switch face {
        case .small, .medium, .large:
            SystemStatsFace(summary: summary, face: face, accented: accented)
        case .rectangular:
            RectangularStatsFace(summary: summary, accented: accented)
        case .circular:
            CircularStatsFace(summary: summary, accented: accented)
        }
    }
}

// MARK: - Pieces

private extension View {
    /// One line that shrinks a little before it truncates (`widgetFit` in
    /// `DoneWidget.swift` is the same idea; that file is the widget's only).
    func statsFit(_ minimumScale: CGFloat = 0.75) -> some View {
        lineLimit(1).minimumScaleFactor(minimumScale).allowsTightening(true)
    }

    /// The header's fit: it shrinks further than a row, since the elapsed
    /// basis's English header for a month is the longest line a face sets
    /// and has the smallest small box's width to fit in
    /// (`CategoryStatsRenderTests.testNoFaceTruncatesAnythingButANameInAnyBox`).
    func statsHeaderFit() -> some View { statsFit(0.65) }
}

let statsTrack = Color.secondary.opacity(CategoryStatsLayout.trackOpacity)

/// A row's colour in the bar. `ranked` is how many categories the bar ranks
/// ahead of its remainder; `dark` is the colour scheme's.
func statsColor(_ row: CategoryStatsRow, accented: Bool, dark: Bool, ranked: Int = 0) -> Color {
    if row.isUnlogged { return statsTrack }
    if accented {
        if case .category(let rank) = row.kind {
            return Color.primary.opacity(CategoryStatsLayout.accentedOpacity(rank: rank))
        }
        return Color.primary.opacity(CategoryStatsLayout.remainderAccentedOpacity(after: ranked))
    }
    guard !row.isRemainder else { return Color(white: CategoryStatsLayout.remainderWhite(dark: dark)) }
    if let hex = row.colorHex, let c = CategoryStatsLayout.rgba(hex: hex) {
        return Color(red: c.red, green: c.green, blue: c.blue, opacity: c.alpha)
    }
    let palette: [Color] = [.blue, .orange, .purple, .green, .pink, .teal, .indigo, .mint, .cyan, .red]
    return palette[WidgetLayout.paletteIndex(for: row.name, count: palette.count)]
}

/// A face's header: the period and its logged hours, or in the elapsed
/// basis the span elapsed; the period alone when there are no numbers.
func categoryStatsHeader(_ summary: CategoryStatsSummary) -> String {
    guard summary.status == .ok else { return LFormat.statsPeriod(summary.period) }
    switch summary.basis {
    case .logged: return LFormat.statsHeader(summary.period, hours: summary.totalHours)
    case .elapsed: return LFormat.statsElapsedHeader(summary.period, hours: summary.elapsedHours)
    }
}

/// The stacked bar: one segment per row with time, in row order — the
/// elapsed basis's unlogged part in the track's colour — over the track
/// an empty bar shows.
struct StatsBar: View {
    let rows: [CategoryStatsRow]
    let accented: Bool
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        let segments = rows.filter { $0.hours > 0 }
        let ranked = rows.filter { !$0.isRemainder && !$0.isUnlogged }.count
        GeometryReader { geo in
            let gap = CategoryStatsLayout.barGap(accented: accented)
            let widths = CategoryStatsLayout.segmentWidths(
                segments.map(\.share), width: geo.size.width, gap: gap, minimum: CategoryStatsLayout.minimumSegment
            )
            HStack(spacing: gap) {
                ForEach(segments.indices, id: \.self) { index in
                    Rectangle()
                        .fill(statsColor(segments[index], accented: accented, dark: colorScheme == .dark,
                                         ranked: ranked))
                        .frame(width: widths[index])
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
        }
        .background(segments.isEmpty ? statsTrack : .clear)
        .clipShape(Capsule())
        .widgetAccentable()
    }
}

/// A row's marker: filled for a category, a ring for the remainder, a short
/// bar of the track for the unlogged time, so none can be mistaken for
/// another.
struct StatsDot: View {
    let row: CategoryStatsRow
    let accented: Bool
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        let color = statsColor(row, accented: accented, dark: colorScheme == .dark)
        Group {
            if row.isRemainder {
                Circle().strokeBorder(accented ? Color.primary.opacity(0.6) : Color.secondary, lineWidth: 1.5)
            } else if row.isUnlogged {
                Capsule()
                    .fill(accented ? Color.primary.opacity(0.35) : Color.secondary.opacity(0.5))
                    .frame(height: CategoryStatsLayout.unloggedMarkerHeight)
            } else {
                Circle().fill(color)
            }
        }
        .frame(width: CategoryStatsLayout.dotSize, height: CategoryStatsLayout.dotSize)
        .widgetAccentable()
    }
}

private struct StatsRow: View {
    let row: CategoryStatsRow
    let face: CategoryStatsFace
    let accented: Bool

    var body: some View {
        let size = CategoryStatsLayout.rowSize(face)
        HStack(spacing: 5) {
            StatsDot(row: row, accented: accented)
            Group {
                switch row.kind {
                case .remainder(let count):
                    Text(LFormat.statsRemainder(count)).foregroundStyle(.secondary)
                case .unlogged:
                    Text(L(.statsUnlogged)).foregroundStyle(.secondary)
                case .category:
                    // A name is the one text a face lets truncate; set
                    // explicitly so the render tests can tell it apart.
                    Text(row.name).truncationMode(.tail)
                }
            }
            .font(.system(size: size, weight: .medium, design: .rounded))
            .statsFit(0.8)
            .frame(maxWidth: .infinity, alignment: .leading)
            if CategoryStatsLayout.showsHours(face) {
                Text(LFormat.statsHours(row.hours))
                    .font(.system(size: size - 1, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
                    .frame(minWidth: 40, alignment: .trailing)
            }
            Text(row.percentText)
                .font(.system(size: size, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
                .frame(minWidth: CategoryStatsLayout.showsHours(face) ? 34 : 0, alignment: .trailing)
        }
    }
}

private struct StatsMessage: View {
    let text: String
    let size: CGFloat

    var body: some View {
        Text(text)
            .font(.system(size: size, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .minimumScaleFactor(0.8)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Faces

/// Home screen, small, medium and large: header, bar, rows.
private struct SystemStatsFace: View {
    let summary: CategoryStatsSummary
    let face: CategoryStatsFace
    let accented: Bool

    var body: some View {
        let cap = CategoryStatsLayout.rowCap(face)
        ViewThatFits(in: .vertical) {
            ForEach(Array((0...cap).reversed()), id: \.self) { rows in
                stack(rows: rows)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func stack(rows count: Int) -> some View {
        let unlogged = summary.unloggedHours
        let rows = CategoryStats.breakdown(summary.categories, maxRows: count, unlogged: unlogged)
        let message = LFormat.statsMessage(summary.status, period: summary.period)
        return VStack(alignment: .leading, spacing: 0) {
            Text(categoryStatsHeader(summary))
                .font(.system(size: CategoryStatsLayout.headerSize(face), weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .statsHeaderFit()
            StatsBar(rows: CategoryStats.breakdown(summary.categories, maxRows: CategoryStatsLayout.barCap(face, accented: accented),
                                                   unlogged: unlogged),
                     accented: accented)
                .frame(height: CategoryStatsLayout.barHeight(face))
                .padding(.top, CategoryStatsLayout.headerToBar(face))
            Group {
                if let message {
                    StatsMessage(text: message, size: CategoryStatsLayout.messageSize(face))
                } else {
                    VStack(alignment: .leading, spacing: CategoryStatsLayout.rowSpacing(face)) {
                        ForEach(rows.indices, id: \.self) { index in
                            StatsRow(row: rows[index], face: face, accented: accented)
                        }
                    }
                }
            }
            .padding(.top, CategoryStatsLayout.barToRows(face))
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

/// Lock screen, rectangular: the header, the bar, the two leaders — in the
/// elapsed basis the leader and the unlogged time — set as tight as the lock
/// screen's box needs.
private struct RectangularStatsFace: View {
    let summary: CategoryStatsSummary
    let accented: Bool

    var body: some View {
        let cap = CategoryStatsLayout.rowCap(.rectangular)
        ViewThatFits(in: .vertical) {
            ForEach(Array((0...cap).reversed()), id: \.self) { rows in
                stack(rows: rows)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func stack(rows count: Int) -> some View {
        let unlogged = summary.unloggedHours
        let rows = CategoryStats.breakdown(summary.categories, maxRows: count, includeRemainder: false,
                                           unlogged: unlogged)
        let message = LFormat.statsMessage(summary.status, period: summary.period)
        return VStack(alignment: .leading, spacing: 0) {
            Text(categoryStatsHeader(summary))
                .font(.system(size: CategoryStatsLayout.headerSize(.rectangular), weight: .semibold, design: .rounded))
                .statsHeaderFit()
            StatsBar(rows: CategoryStats.breakdown(summary.categories, maxRows: CategoryStatsLayout.barCap(.rectangular, accented: accented),
                                                   unlogged: unlogged),
                     accented: accented)
                .frame(height: CategoryStatsLayout.barHeight(.rectangular))
                .padding(.top, CategoryStatsLayout.headerToBar(.rectangular))
            Group {
                if let message {
                    StatsMessage(text: message, size: 12)
                } else {
                    VStack(alignment: .leading, spacing: CategoryStatsLayout.rowSpacing(.rectangular)) {
                        ForEach(rows.indices, id: \.self) { index in
                            StatsRow(row: rows[index], face: .rectangular, accented: accented)
                        }
                    }
                }
            }
            .padding(.top, CategoryStatsLayout.barToRows(.rectangular))
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

/// Lock screen, circular: the leading category's share of the active basis
/// as a gauge.
private struct CircularStatsFace: View {
    let summary: CategoryStatsSummary
    let accented: Bool
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        GeometryReader { geo in
            let diameter = min(geo.size.width, geo.size.height)
            let line = max(3, (diameter * 0.075).rounded())
            let top = CategoryStatsLayout.ringLeader(summary)
            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.2), lineWidth: line)
                if let top {
                    Circle()
                        .trim(from: 0, to: CGFloat(min(max(top.share, 0), 1)))
                        .stroke(accented
                                    ? Color.primary : statsColor(top, accented: false, dark: colorScheme == .dark),
                                style: StrokeStyle(lineWidth: line, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .widgetAccentable()
                }
                // Inside the ring's inner edge, with the corners of a
                // two-line block clear of it. The percent shrinks rather
                // than lose its "%": "100%" with Bold Text in the smallest
                // ring needs more than a row's floor allows
                // (`CategoryStatsRenderTests.testTheRingsHundredPercentFitsEveryRing`).
                VStack(spacing: 0) {
                    Text(top?.percentText ?? "--")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .statsFit(0.6)
                    if let top {
                        Text(top.name)
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                            .statsFit(0.8)
                            .truncationMode(.tail)
                    }
                }
                .frame(width: max(0, (diameter - 2 * line) * 0.72))
            }
            // A stroke straddles its path: inset by half a line so the ring's
            // outer edge is the box's.
            .padding(line / 2)
            .frame(width: diameter, height: diameter)
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}
