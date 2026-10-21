import SwiftUI
import WidgetKit

/// One stretch of the gauge's arc, in degrees clockwise from 3 o'clock
/// (SwiftUI's convention). `row` is `nil` only for the empty gauge's track.
nonisolated struct CategoryGaugeSegment: Equatable {
    enum Role: Equatable {
        case category(rank: Int)
        case remainder
        case track
    }

    var start: Double
    var end: Double
    var row: CategoryStatsRow?

    var sweep: Double { end - start }

    var role: Role {
        guard let row else { return .track }
        switch row.kind {
        case .category(let rank): return .category(rank: rank)
        case .remainder: return .remainder
        case .unlogged: return .track
        }
    }
}

/// Numbers and pure helpers for the "Category Gauge" widget: the category
/// split of "Time by Category" as a 270° arc open at the bottom, the hours
/// logged in its middle.
/// Here rather than in `DoneWidget/` for the same reason as
/// `CategoryStatsLayout`: `DoneTests` renders it (`CategoryGaugeRenderTests`).
enum CategoryGaugeLayout {
    static let startAngle = 135.0
    static let span = 270.0
    /// Categories drawn before the rest share one remainder segment. In full
    /// colour none: every category the user made has its own colour and its
    /// own segment. Without colour, as many as the faces' opacity ladder has
    /// rungs above the remainder's, so no two segments share a tone.
    static func categoryCap(accented: Bool) -> Int? { accented ? 4 : nil }
    /// The stroke, as a share of the arc's outer diameter: the hole is a
    /// little over half the diameter, so the arc reads as a pie with a bite
    /// out rather than a thin gauge.
    static let lineWidthRatio = 0.22
    /// Background between neighbouring segments, along the stroke's centre line.
    static let jointGap: CGFloat = 2
    /// The least ink a segment with any time keeps, along the centre line.
    static let minimumInk: CGFloat = 2
    /// Without gaps, how far an opaque segment runs on under the next one,
    /// along the centre line: two antialiased edges meeting on one line let
    /// the background through as a seam.
    static let seamOverlap: CGFloat = 1

    /// How far `segment` is drawn past its end: under the next segment when
    /// both are opaque and abut, and not otherwise — under or over a
    /// translucent one the overlap would show.
    static func drawnPastEnd(_ segment: CategoryGaugeSegment, next: CategoryGaugeSegment?, accented: Bool,
                             overlap: Double) -> Double {
        guard !accented, let next, next.start <= segment.end, isOpaque(segment), isOpaque(next) else { return 0 }
        return overlap
    }

    /// Whether a segment is drawn opaque in full colour: not the track, and
    /// not a category whose colour the user gave some transparency.
    static func isOpaque(_ segment: CategoryGaugeSegment) -> Bool {
        guard let row = segment.row, !row.isUnlogged else { return false }
        guard let hex = row.colorHex, let c = CategoryStatsLayout.rgba(hex: hex) else { return true }
        return c.alpha >= 1
    }

    /// The rows the arc walks, in the list's order: the categories (without
    /// colour, the leaders and the remainder), and in the elapsed basis the
    /// unlogged time last. Rows without time are left out.
    static func rows(_ summary: CategoryStatsSummary, accented: Bool) -> [CategoryStatsRow] {
        guard summary.status == .ok else { return [] }
        let unlogged = summary.unloggedHours
        let slots = categoryCap(accented: accented).map { $0 + 1 } ?? summary.categories.count
        return CategoryStats.breakdown(summary.categories, maxRows: slots + (unlogged == nil ? 0 : 1),
                                       unlogged: unlogged)
            .filter { $0.hours > 0 && $0.share.isFinite && $0.share > 0 }
    }

    /// The arc cut into `rows`, `gap` degrees apart. Ink is split by share
    /// across what the gaps leave of the span; a segment that would get less
    /// than `minimum` degrees gets `minimum`, taken from the others by share,
    /// unless every segment at `minimum` would not fit; with more segments
    /// than the gaps leave room for, the gaps go too. The segments and gaps
    /// always cover exactly the span. No rows: the track alone.
    static func segments(_ rows: [CategoryStatsRow], gap: Double, minimum: Double) -> [CategoryGaugeSegment] {
        guard !rows.isEmpty else {
            return [CategoryGaugeSegment(start: startAngle, end: startAngle + span, row: nil)]
        }
        let gap = max(0, gap) * Double(rows.count - 1) < span ? max(0, gap) : 0
        let available = span - gap * Double(rows.count - 1)
        let sweeps = sweeps(rows.map(\.share), total: available, minimum: max(0, minimum))
        var result: [CategoryGaugeSegment] = []
        var cursor = startAngle
        for (index, row) in rows.enumerated() {
            let end = index == rows.count - 1 ? startAngle + span : cursor + sweeps[index]
            result.append(CategoryGaugeSegment(start: cursor, end: end, row: row))
            cursor = end + gap
        }
        return result
    }

    /// `total` split by `shares`, each part at least `minimum` when all fit.
    static func sweeps(_ shares: [Double], total: Double, minimum: Double) -> [Double] {
        let clean = shares.map { $0.isFinite ? max(0, $0) : 0 }
        guard clean.reduce(0, +) > 0 else { return clean.map { _ in total / Double(max(clean.count, 1)) } }
        let floor = Double(clean.count) * minimum <= total ? minimum : 0
        var lifted = Set<Int>()
        while true {
            let free = clean.indices.filter { !lifted.contains($0) }
            let freeShare = free.reduce(0) { $0 + clean[$1] }
            let room = total - floor * Double(lifted.count)
            let short = free.filter { freeShare <= 0 || clean[$0] / freeShare * room < floor }
            if short.isEmpty {
                return clean.indices.map { lifted.contains($0) ? floor : clean[$0] / freeShare * room }
            }
            lifted.formUnion(short)
        }
    }

    /// Points along a circle of `radius` as degrees of its arc.
    static func degrees(points: CGFloat, radius: CGFloat) -> Double {
        radius > 0 ? Double(points / radius) * 180 / .pi : 0
    }

    /// The arc's caps sit inside the span: the stroke runs this far in from
    /// each end, so its round cap reaches the end and adds nothing to the
    /// first and last segments' share.
    static func capInset(lineWidth: CGFloat, radius: CGFloat) -> Double {
        degrees(points: lineWidth / 2, radius: radius)
    }

    struct Fit: Equatable {
        var center: CGPoint
        /// The stroke's centre line.
        var radius: CGFloat
        var lineWidth: CGFloat
    }

    /// The largest arc `size` holds, its bounding box (round caps included)
    /// centred in `size`. The gap at the bottom makes the box wider than tall,
    /// so the circle's centre sits below the box's middle.
    static func fit(in size: CGSize) -> Fit {
        let w = lineWidthRatio, r = 0.5 - w / 2
        let cap = (startAngle + capInset(lineWidth: w, radius: r)) * .pi / 180
        let below = max(r * sin(cap) + w / 2, 0)
        let height = 0.5 + below
        let diameter = max(0, min(size.width, size.height / height))
        let top = (size.height - height * diameter) / 2
        return Fit(center: CGPoint(x: size.width / 2, y: top + diameter / 2),
                   radius: diameter * r, lineWidth: diameter * w)
    }

    /// The words in the gauge's middle: the hours logged in the period, big,
    /// with their unit, and the period under them. "--" when there is
    /// nothing to read.
    static func centre(_ summary: CategoryStatsSummary) -> (value: String, unit: String, caption: String) {
        let caption = LFormat.statsPeriod(summary.period)
        switch summary.status {
        case .noData, .stale: return ("--", "", caption)
        case .empty, .ok:
            let unit = L(.statsHoursFormat).replacingOccurrences(of: "%@", with: "").trimmingCharacters(in: .whitespaces)
            return (LFormat.statsHoursNumber(summary.totalHours), unit, caption)
        }
    }

    /// The radius the middle's words stay inside: the hole the band leaves,
    /// less a clearance so no glyph touches the band.
    static func wordsRadius(_ fit: Fit) -> CGFloat {
        max(0, fit.radius - fit.lineWidth / 2 - holeClearance)
    }

    static let holeClearance: CGFloat = 3

    /// What VoiceOver reads: the face's header as the label; the rows drawn
    /// in this rendering mode with their percents, or the face's message, as
    /// the value.
    static func spoken(_ summary: CategoryStatsSummary, accented: Bool) -> (label: String, value: String) {
        let label = categoryStatsHeader(summary)
        if let message = LFormat.statsMessage(summary.status, period: summary.period) { return (label, message) }
        let parts = rows(summary, accented: accented).map { row -> String in
            let name: String
            switch row.kind {
            case .category: name = row.name
            case .remainder(let count): name = LFormat.statsRemainder(count)
            case .unlogged: name = L(.statsUnlogged)
            }
            return "\(name) \(row.percentText)"
        }
        return (label, parts.joined(separator: ", "))
    }
}

private struct GaugeArc: Shape {
    let start: Double
    let end: Double
    let center: CGPoint
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addArc(center: center, radius: radius, startAngle: .degrees(start), endAngle: .degrees(end),
                    clockwise: false)
        return path
    }
}

/// The gauge face. `accented` is the widget's rendering mode being anything
/// but full colour; `showsGaps` the widget's setting, in either mode.
struct CategoryGaugeWidgetView: View {
    let summary: CategoryStatsSummary
    let accented: Bool
    let showsGaps: Bool
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        let rows = CategoryGaugeLayout.rows(summary, accented: accented)
        let ranked = rows.filter { !$0.isRemainder && !$0.isUnlogged }.count
        let spoken = CategoryGaugeLayout.spoken(summary, accented: accented)
        GeometryReader { geo in
            let fit = CategoryGaugeLayout.fit(in: geo.size)
            let segments = CategoryGaugeLayout.segments(
                rows,
                gap: showsGaps ? CategoryGaugeLayout.degrees(points: CategoryGaugeLayout.jointGap, radius: fit.radius) : 0,
                minimum: CategoryGaugeLayout.degrees(points: CategoryGaugeLayout.minimumInk, radius: fit.radius)
            )
            let inset = CategoryGaugeLayout.capInset(lineWidth: fit.lineWidth, radius: fit.radius)
            let overlap = CategoryGaugeLayout.degrees(points: CategoryGaugeLayout.seamOverlap, radius: fit.radius)
            ZStack {
                ZStack {
                    ForEach(segments.indices, id: \.self) { index in
                        let next = index + 1 < segments.count ? segments[index + 1] : nil
                        GaugeArc(start: segments[index].start,
                                 end: segments[index].end + CategoryGaugeLayout.drawnPastEnd(
                                    segments[index], next: next, accented: accented, overlap: overlap),
                                 center: fit.center, radius: fit.radius)
                            .stroke(color(segments[index], ranked: ranked),
                                    style: StrokeStyle(lineWidth: fit.lineWidth, lineCap: .butt))
                    }
                }
                .mask {
                    GaugeArc(start: CategoryGaugeLayout.startAngle + inset,
                             end: CategoryGaugeLayout.startAngle + CategoryGaugeLayout.span - inset,
                             center: fit.center, radius: fit.radius)
                        .stroke(style: StrokeStyle(lineWidth: fit.lineWidth, lineCap: .round))
                }
                .widgetAccentable()
                GaugeWords(words: CategoryGaugeLayout.centre(summary), radius: CategoryGaugeLayout.wordsRadius(fit))
                    .position(fit.center)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken.label)
        .accessibilityValue(spoken.value)
    }

    private func color(_ segment: CategoryGaugeSegment, ranked: Int) -> Color {
        guard let row = segment.row else { return statsTrack }
        return statsColor(row, accented: accented, dark: colorScheme == .dark, ranked: ranked)
    }
}

/// The gauge's middle: the hours, the period under them, set in a box the
/// circle of `radius` holds (its corners at 0.97 of the radius).
private struct GaugeWords: View {
    let words: (value: String, unit: String, caption: String)
    let radius: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            Text("\(Text(words.value).font(.system(size: radius * 0.64, weight: .bold, design: .rounded)))\(Text(words.unit).font(.system(size: radius * 0.34, weight: .semibold, design: .rounded)))")
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text(words.caption)
                .font(.system(size: max(9, radius * 0.3), weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(width: radius * 1.6, height: radius * 1.1)
    }
}
