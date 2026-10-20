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
/// split of "Time by Category" as a 270° arc open at the bottom, no text.
/// Here rather than in `DoneWidget/` for the same reason as
/// `CategoryStatsLayout`: `DoneTests` renders it (`CategoryGaugeRenderTests`).
enum CategoryGaugeLayout {
    static let startAngle = 135.0
    static let span = 270.0
    /// Categories drawn before the rest share one remainder segment.
    static let categoryCap = 6
    /// The stroke, as a share of the arc's outer diameter: the hole is a
    /// little over half the diameter, so the arc reads as a pie with a bite
    /// out rather than a thin gauge.
    static let lineWidthRatio = 0.22
    /// Background between neighbouring segments, along the stroke's centre line.
    static let jointGap: CGFloat = 2
    /// The least ink a segment with any time keeps, along the centre line.
    static let minimumInk: CGFloat = 2

    /// The rows the arc walks, in the list's order: the leaders, the
    /// remainder, and in the elapsed basis the unlogged time last. Rows
    /// without time are left out.
    static func rows(_ summary: CategoryStatsSummary) -> [CategoryStatsRow] {
        guard summary.status == .ok else { return [] }
        let unlogged = summary.unloggedHours
        return CategoryStats.breakdown(summary.categories, maxRows: categoryCap + 1 + (unlogged == nil ? 0 : 1),
                                       unlogged: unlogged)
            .filter { $0.hours > 0 && $0.share.isFinite && $0.share > 0 }
    }

    /// The arc cut into `rows`, `gap` degrees apart. Ink is split by share
    /// across what the gaps leave of the span; a segment that would get less
    /// than `minimum` degrees gets `minimum`, taken from the others by share,
    /// unless every segment at `minimum` would not fit. The segments and gaps
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

    /// What VoiceOver reads: the face's header as the label; the rows with
    /// their percents, or the face's message, as the value.
    static func spoken(_ summary: CategoryStatsSummary) -> (label: String, value: String) {
        let label = categoryStatsHeader(summary)
        if let message = LFormat.statsMessage(summary.status, period: summary.period) { return (label, message) }
        let parts = rows(summary).map { row -> String in
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
/// but full colour.
struct CategoryGaugeWidgetView: View {
    let summary: CategoryStatsSummary
    let accented: Bool
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        let rows = CategoryGaugeLayout.rows(summary)
        let ranked = rows.filter { !$0.isRemainder && !$0.isUnlogged }.count
        let spoken = CategoryGaugeLayout.spoken(summary)
        GeometryReader { geo in
            let fit = CategoryGaugeLayout.fit(in: geo.size)
            let segments = CategoryGaugeLayout.segments(
                rows,
                gap: CategoryGaugeLayout.degrees(points: CategoryGaugeLayout.jointGap, radius: fit.radius),
                minimum: CategoryGaugeLayout.degrees(points: CategoryGaugeLayout.minimumInk, radius: fit.radius)
            )
            let inset = CategoryGaugeLayout.capInset(lineWidth: fit.lineWidth, radius: fit.radius)
            ZStack {
                ForEach(segments.indices, id: \.self) { index in
                    GaugeArc(start: segments[index].start, end: segments[index].end,
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
