import SwiftUI
import WidgetKit

/// The faces of the "Time by Category" widget, one per supported family.
enum CategoryStatsFace: CaseIterable {
    case small
    case medium
    case rectangular
    case circular
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
    static func rowCap(_ face: CategoryStatsFace) -> Int {
        switch face {
        case .small: return 3
        case .medium: return 5
        case .rectangular: return 2
        case .circular: return 1
        }
    }

    /// How many categories the bar splits into before the rest share one
    /// segment: as many as the face lists, plus the rest, on the lock screen.
    static func barCap(_ face: CategoryStatsFace) -> Int {
        face == .rectangular ? 3 : rowCap(face)
    }

    static let headerSize: CGFloat = 12
    static let messageSize: CGFloat = 13
    static func rowSize(_ face: CategoryStatsFace) -> CGFloat { face == .small ? 13 : 12 }
    static func barHeight(_ face: CategoryStatsFace) -> CGFloat { face == .rectangular ? 6 : 8 }
    /// The medium face sets its rows closer, so a full list fits the
    /// smallest medium box (`CategoryStatsRenderTests` counts the rows).
    static func headerToBar(_ face: CategoryStatsFace) -> CGFloat { face == .medium ? 5 : 6 }
    static func barToRows(_ face: CategoryStatsFace) -> CGFloat { face == .medium ? 6 : 8 }
    static func rowSpacing(_ face: CategoryStatsFace) -> CGFloat { face == .medium ? 2 : 4 }
    static let dotSize: CGFloat = 7
    static let minimumSegment: CGFloat = 2

    /// Without colour (tinted home screen, lock screen) segments are told
    /// apart by a gap and by opacity, which falls with rank.
    static func barGap(accented: Bool) -> CGFloat { accented ? 2 : 1 }

    static func accentedOpacity(rank: Int) -> Double {
        let ladder = [1.0, 0.72, 0.52, 0.38, 0.3]
        return ladder[min(max(rank, 0), ladder.count - 1)]
    }

    static let remainderAccentedOpacity = 0.18

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

    /// What the gallery and the placeholder show: a plausible week.
    static func sample(_ period: CategoryStatsPeriod, chinese: Bool) -> CategoryStatsSummary {
        let names = chinese ? ["深度工作", "会议", "运动", "阅读", "家务"] : ["Deep Work", "Meetings", "Exercise", "Reading", "Chores"]
        let colors = ["#5E5CE6", "#FF9F0A", "#30D158", "#0A84FF", "#BF5AF2"]
        let hours: [Double] = [13.6, 8.1, 3.3, 4.5, 3]
        let categories = zip(zip(names, colors), hours)
            .map { CategoryHours(name: $0.0, colorHex: $0.1, hours: $1) }
            .sorted { $0.hours > $1.hours }
        return CategoryStatsSummary(period: period, status: .ok, categories: categories,
                                    totalHours: hours.reduce(0, +))
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
        case .small, .medium:
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
}

private func statsColor(_ row: CategoryStatsRow, accented: Bool) -> Color {
    if accented {
        if case .category(let rank) = row.kind {
            return Color.primary.opacity(CategoryStatsLayout.accentedOpacity(rank: rank))
        }
        return Color.primary.opacity(CategoryStatsLayout.remainderAccentedOpacity)
    }
    guard !row.isRemainder else { return Color.secondary.opacity(0.45) }
    if let hex = row.colorHex, let c = CategoryStatsLayout.rgba(hex: hex) {
        return Color(red: c.red, green: c.green, blue: c.blue, opacity: c.alpha)
    }
    let palette: [Color] = [.blue, .orange, .purple, .green, .pink, .teal, .indigo, .mint, .cyan, .red]
    return palette[WidgetLayout.paletteIndex(for: row.name, count: palette.count)]
}

private func statsHeader(_ summary: CategoryStatsSummary) -> String {
    summary.status == .ok
        ? LFormat.statsHeader(summary.period, hours: summary.totalHours)
        : LFormat.statsPeriod(summary.period)
}

/// The stacked bar: one segment per row, in row order, over a track.
private struct StatsBar: View {
    let rows: [CategoryStatsRow]
    let accented: Bool

    var body: some View {
        GeometryReader { geo in
            let gap = CategoryStatsLayout.barGap(accented: accented)
            let widths = CategoryStatsLayout.segmentWidths(
                rows.map(\.share), width: geo.size.width, gap: gap, minimum: CategoryStatsLayout.minimumSegment
            )
            HStack(spacing: gap) {
                ForEach(rows.indices, id: \.self) { index in
                    Rectangle()
                        .fill(statsColor(rows[index], accented: accented))
                        .frame(width: widths[index])
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
        }
        .background(Color.secondary.opacity(rows.isEmpty ? 0.2 : 0))
        .clipShape(Capsule())
        .widgetAccentable()
    }
}

/// A row's marker: filled for a category, a ring for the remainder, so the
/// two can never be mistaken for each other.
private struct StatsDot: View {
    let row: CategoryStatsRow
    let accented: Bool

    var body: some View {
        let color = statsColor(row, accented: accented)
        Group {
            if row.isRemainder {
                Circle().strokeBorder(accented ? Color.primary.opacity(0.6) : Color.secondary, lineWidth: 1.5)
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
                if case .remainder(let count) = row.kind {
                    Text(LFormat.statsRemainder(count)).foregroundStyle(.secondary)
                } else {
                    Text(row.name)
                }
            }
            .font(.system(size: size, weight: .medium, design: .rounded))
            .statsFit(0.8)
            .frame(maxWidth: .infinity, alignment: .leading)
            if face == .medium {
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
                .frame(minWidth: face == .medium ? 34 : 0, alignment: .trailing)
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

/// Home screen, small and medium: header, bar, rows.
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
        let rows = CategoryStats.breakdown(summary.categories, maxRows: count)
        let message = LFormat.statsMessage(summary.status, period: summary.period)
        return VStack(alignment: .leading, spacing: 0) {
            Text(statsHeader(summary))
                .font(.system(size: CategoryStatsLayout.headerSize, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .statsFit()
            StatsBar(rows: CategoryStats.breakdown(summary.categories, maxRows: CategoryStatsLayout.barCap(face)),
                     accented: accented)
                .frame(height: CategoryStatsLayout.barHeight(face))
                .padding(.top, CategoryStatsLayout.headerToBar(face))
            Group {
                if let message {
                    StatsMessage(text: message, size: CategoryStatsLayout.messageSize)
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

/// Lock screen, rectangular: the header, the bar, the two leaders.
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
        let rows = CategoryStats.breakdown(summary.categories, maxRows: count, includeRemainder: false)
        let message = LFormat.statsMessage(summary.status, period: summary.period)
        return VStack(alignment: .leading, spacing: 3) {
            Text(statsHeader(summary))
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .statsFit()
            StatsBar(rows: CategoryStats.breakdown(summary.categories, maxRows: CategoryStatsLayout.barCap(.rectangular)),
                     accented: accented)
                .frame(height: CategoryStatsLayout.barHeight(.rectangular))
            if let message {
                StatsMessage(text: message, size: 12)
            } else {
                ForEach(rows.indices, id: \.self) { index in
                    StatsRow(row: rows[index], face: .rectangular, accented: accented)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

/// Lock screen, circular: the leading category's share as a gauge.
private struct CircularStatsFace: View {
    let summary: CategoryStatsSummary
    let accented: Bool

    var body: some View {
        GeometryReader { geo in
            let diameter = min(geo.size.width, geo.size.height)
            let line = max(3, (diameter * 0.075).rounded())
            let top = summary.status == .ok ? CategoryStats.breakdown(summary.categories, maxRows: 1).first : nil
            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.2), lineWidth: line)
                if let top {
                    Circle()
                        .trim(from: 0, to: CGFloat(min(max(top.share, 0), 1)))
                        .stroke(accented ? Color.primary : statsColor(top, accented: false),
                                style: StrokeStyle(lineWidth: line, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .widgetAccentable()
                }
                // Inside the ring's inner edge, with the corners of a
                // two-line block clear of it.
                VStack(spacing: 0) {
                    Text(top?.percentText ?? "--")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .statsFit(0.7)
                    if let top {
                        Text(top.name)
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                            .statsFit(0.8)
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
