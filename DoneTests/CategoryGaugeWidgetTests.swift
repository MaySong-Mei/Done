import XCTest
import SwiftUI
@testable import Done

private func gaugeSummary(_ hours: [Double], elapsed: Double? = nil, period: CategoryStatsPeriod = .week,
                          colors: Bool = true) -> CategoryStatsSummary {
    let palette = ["#5E5CE6", "#FF9F0A", "#30D158", "#0A84FF", "#BF5AF2", "#64D2FF", "#FF375F", "#FFD60A", "#AC8E68"]
    var unsorted: [CategoryHours] = []
    for (index, value) in hours.enumerated() {
        let hex: String? = colors ? palette[index % palette.count] : nil
        unsorted.append(CategoryHours(name: "C\(index)", colorHex: hex, hours: value))
    }
    let categories = unsorted.sorted { $0.hours == $1.hours ? $0.name < $1.name : $0.hours > $1.hours }
    return CategoryStatsSummary(period: period, basis: elapsed == nil ? .logged : .elapsed, status: .ok,
                                categories: categories, totalHours: hours.reduce(0, +), elapsedHours: elapsed ?? 0)
}

@MainActor
private func fullColorRows(_ summary: CategoryStatsSummary) -> [CategoryStatsRow] {
    CategoryGaugeLayout.rows(summary, accented: false)
}

// MARK: - Geometry

@MainActor
final class CategoryGaugeLayoutTests: XCTestCase {
    private let gap = 2.5
    private let minimum = 2.5

    private func assertCoversTheSpan(_ segments: [CategoryGaugeSegment], gap: Double, _ label: String) {
        XCTAssertEqual(segments.first?.start ?? .nan, 135, accuracy: 1e-9, label)
        XCTAssertEqual(segments.last?.end ?? .nan, 405, accuracy: 1e-9, label)
        for (a, b) in zip(segments, segments.dropFirst()) {
            XCTAssertEqual(b.start - a.end, gap, accuracy: 1e-9, "\(label): joint")
        }
        let ink = segments.reduce(0) { $0 + $1.sweep }
        XCTAssertEqual(ink + gap * Double(segments.count - 1), 270, accuracy: 1e-9, label)
        XCTAssertTrue(segments.allSatisfy { $0.sweep > 0 }, label)
    }

    func testTheArcIsTheBottomlessThreeQuarters() {
        XCTAssertEqual(CategoryGaugeLayout.startAngle, 135)
        XCTAssertEqual(CategoryGaugeLayout.span, 270)
        XCTAssertEqual(CategoryGaugeLayout.categoryCap(accented: false), 6)
        XCTAssertEqual(CategoryGaugeLayout.categoryCap(accented: true), 4)
    }

    /// Logged basis: the categories fill the arc, split by share.
    func testLoggedSweepsFillTheSpanByShare() {
        let summary = gaugeSummary([6, 3, 1])
        let rows = CategoryGaugeLayout.rows(summary, accented: false)
        let segments = CategoryGaugeLayout.segments(rows, gap: gap, minimum: minimum)
        assertCoversTheSpan(segments, gap: gap, "logged")
        let available = 270 - gap * 2
        for (segment, share) in zip(segments, [0.6, 0.3, 0.1]) {
            XCTAssertEqual(segment.sweep, share * available, accuracy: 1e-9)
        }
        XCTAssertFalse(segments.contains { $0.role == .track }, "the logged arc is all colour")
    }

    /// The arc walks the list's rows in the list's order.
    func testTheOrderIsTheRowsOrder() {
        for summary in [gaugeSummary([1, 7, 3, 5, 2]), gaugeSummary([1, 7, 3, 5, 2], elapsed: 40),
                        gaugeSummary([4, 4, 4, 1, 9, 2, 3, 8, 5])] {
            let rows = CategoryGaugeLayout.rows(summary, accented: false)
            let segments = CategoryGaugeLayout.segments(rows, gap: gap, minimum: minimum)
            XCTAssertEqual(segments.map(\.row), rows)
            let hours = segments.compactMap { segment -> Double? in
                if case .category = segment.role { return segment.row?.hours }
                return nil
            }
            XCTAssertEqual(hours, hours.sorted(by: >), "most hours first")
            for (a, b) in zip(segments, segments.dropFirst()) { XCTAssertLessThan(a.start, b.start) }
        }
    }

    /// Elapsed basis: the logged rows take their share of the span and the
    /// unlogged time is the track, last.
    func testElapsedEndsInTheTrack() {
        let summary = gaugeSummary([6, 3, 1], elapsed: 40)
        let rows = CategoryGaugeLayout.rows(summary, accented: false)
        let segments = CategoryGaugeLayout.segments(rows, gap: gap, minimum: minimum)
        assertCoversTheSpan(segments, gap: gap, "elapsed")
        XCTAssertEqual(segments.map(\.role), [.category(rank: 0), .category(rank: 1), .category(rank: 2), .track])
        let available = 270 - gap * 3
        XCTAssertEqual(segments[3].sweep, 30.0 / 40 * available, accuracy: 1e-9)
        let logged = segments.dropLast().reduce(0) { $0 + $1.sweep }
        XCTAssertEqual(logged, 10.0 / 40 * available, accuracy: 1e-9)
        XCTAssertEqual(segments[0].sweep, 6.0 / 40 * available, accuracy: 1e-9)
    }

    /// A span logged to the minute has no track.
    func testAFullyLoggedSpanHasNoTrack() {
        let segments = CategoryGaugeLayout.segments(fullColorRows(gaugeSummary([8, 2], elapsed: 10)),
                                                    gap: gap, minimum: minimum)
        XCTAssertEqual(segments.map(\.role), [.category(rank: 0), .category(rank: 1)])
    }

    /// Six categories, then one remainder for the rest — in either basis.
    func testTheRemainder() {
        let hours: [Double] = [9, 8, 7, 6, 5, 4, 3, 2, 1]
        let logged = CategoryGaugeLayout.segments(fullColorRows(gaugeSummary(hours)), gap: gap, minimum: minimum)
        XCTAssertEqual(logged.map(\.role), (0..<6).map { .category(rank: $0) } + [.remainder])
        XCTAssertEqual(logged.last?.row?.kind, .remainder(count: 3))
        let available = 270 - gap * 6
        XCTAssertEqual(logged.last!.sweep, 6.0 / 45 * available, accuracy: 1e-9)

        let elapsed = CategoryGaugeLayout.segments(fullColorRows(gaugeSummary(hours, elapsed: 90)),
                                                   gap: gap, minimum: minimum)
        XCTAssertEqual(elapsed.map(\.role), (0..<6).map { .category(rank: $0) } + [.remainder, .track])
        XCTAssertEqual(elapsed[6].row?.kind, .remainder(count: 3))

        let seven = fullColorRows(gaugeSummary(Array(hours.prefix(7))))
        XCTAssertEqual(seven.count, 7, "no remainder standing for a single category")
        XCTAssertFalse(seven.contains { $0.isRemainder })
    }

    /// Nothing to show: the track alone, the whole arc.
    func testTheEmptyGaugeIsTheTrack() {
        let empties = [
            CategoryStatsSummary(period: .week, status: .empty, categories: [], totalHours: 0),
            CategoryStatsSummary(period: .month, status: .noData, categories: [], totalHours: 0),
            CategoryStatsSummary(period: .today, status: .stale, categories: [], totalHours: 0),
            CategoryStatsSummary(period: .today, basis: .elapsed, status: .empty, categories: [], totalHours: 0),
        ]
        for summary in empties {
            let segments = CategoryGaugeLayout.segments(CategoryGaugeLayout.rows(summary, accented: false), gap: gap, minimum: minimum)
            XCTAssertEqual(segments, [CategoryGaugeSegment(start: 135, end: 405, row: nil)])
            XCTAssertEqual(segments[0].role, .track)
        }
        let nothingLogged = CategoryGaugeLayout.segments(fullColorRows(gaugeSummary([], elapsed: 14)),
                                                         gap: gap, minimum: minimum)
        XCTAssertEqual(nothingLogged.map(\.role), [.track])
        XCTAssertEqual(nothingLogged[0].sweep, 270, accuracy: 1e-9)
    }

    /// A sliver is lifted to the minimum and no further; the rest keep their
    /// proportions to one another. When every segment at the minimum would
    /// not fit, nothing is lifted.
    func testTheMinimumSweep() {
        let rows = fullColorRows(gaugeSummary([500, 300, 0.2]))
        let segments = CategoryGaugeLayout.segments(rows, gap: gap, minimum: minimum)
        assertCoversTheSpan(segments, gap: gap, "sliver")
        XCTAssertEqual(segments[2].sweep, minimum, accuracy: 1e-9)
        XCTAssertEqual(segments[0].sweep / segments[1].sweep, 5.0 / 3, accuracy: 1e-9)

        let crowded = CategoryGaugeLayout.sweeps([0.5, 0.3, 0.2], total: 6, minimum: 3)
        XCTAssertEqual(crowded[0], 3, accuracy: 1e-9)
        XCTAssertEqual(crowded[2], 1.2, accuracy: 1e-9)
        XCTAssertEqual(CategoryGaugeLayout.sweeps([0.5, 0.5], total: 10, minimum: 1), [5, 5])
    }

    /// The arc's box, caps included, sits inside every box it is fitted to,
    /// centred, touching two opposite sides.
    func testTheFitStaysInTheBox() {
        for size in CategoryGaugeRenderTests.boxes + [CGSize(width: 200, height: 90), CGSize(width: 90, height: 200)] {
            let fit = CategoryGaugeLayout.fit(in: size)
            let w = fit.lineWidth, r = fit.radius
            XCTAssertEqual(w / (2 * r + w), CGFloat(CategoryGaugeLayout.lineWidthRatio), accuracy: 1e-9)
            var minX = CGFloat.infinity, maxX = -CGFloat.infinity, minY = CGFloat.infinity, maxY = -CGFloat.infinity
            let inset = CategoryGaugeLayout.capInset(lineWidth: w, radius: r)
            for step in 0...2700 {
                let angle = (135 + inset + (270 - 2 * inset) * Double(step) / 2700) * .pi / 180
                for offset in stride(from: -w / 2, through: w / 2, by: w / 8) {
                    let x = fit.center.x + (r + offset) * cos(angle), y = fit.center.y + (r + offset) * sin(angle)
                    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                }
            }
            for end in [135 + inset, 405 - inset] {
                let cx = fit.center.x + r * cos(end * .pi / 180), cy = fit.center.y + r * sin(end * .pi / 180)
                minX = min(minX, cx - w / 2); maxX = max(maxX, cx + w / 2); maxY = max(maxY, cy + w / 2)
            }
            let label = "\(size)"
            XCTAssertGreaterThanOrEqual(minX, -1e-6, label); XCTAssertLessThanOrEqual(maxX, size.width + 1e-6, label)
            XCTAssertGreaterThanOrEqual(minY, -1e-6, label); XCTAssertLessThanOrEqual(maxY, size.height + 1e-6, label)
            XCTAssertEqual(minY, size.height - maxY, accuracy: 0.05, "\(label): centred vertically")
            XCTAssertEqual(minX, size.width - maxX, accuracy: 0.05, "\(label): centred horizontally")
            XCTAssertTrue(abs(minX) < 0.05 || abs(minY) < 0.05, "\(label): as large as the box allows")
        }
    }

    /// VoiceOver reads the header and the rows with their percents, or the
    /// face's message.
    @MainActor
    func testWhatVoiceOverReads() {
        let saved = UserDefaults.standard.string(forKey: AppSettingsLocale.languageKey)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: AppSettingsLocale.languageKey) }
            else { UserDefaults.standard.removeObject(forKey: AppSettingsLocale.languageKey) }
        }
        UserDefaults.standard.set("en", forKey: AppSettingsLocale.languageKey)
        let elapsed = CategoryGaugeLayout.spoken(gaugeSummary([9, 8, 7, 6, 5, 4, 3, 2, 1], elapsed: 90), accented: false)
        XCTAssertEqual(elapsed.label, "This Week · 90h elapsed")
        XCTAssertEqual(elapsed.value, "C0 10%, C1 9%, C2 8%, C3 7%, C4 5%, C5 4%, 3 more 7%, Unlogged 50%")
        let empty = CategoryGaugeLayout.spoken(CategoryStatsSummary(period: .week, status: .empty, categories: [],
                                                                    totalHours: 0), accented: false)
        XCTAssertEqual(empty.label, "This Week")
        XCTAssertEqual(empty.value, "Nothing logged this week")
        UserDefaults.standard.set("zh", forKey: AppSettingsLocale.languageKey)
        XCTAssertTrue(CategoryGaugeLayout.spoken(gaugeSummary([9, 8, 7, 6, 5, 4, 3, 2, 1]), accented: false).value.contains("其余 3 类"))
        UserDefaults.standard.set("en", forKey: AppSettingsLocale.languageKey)
        XCTAssertEqual(CategoryGaugeLayout.spoken(gaugeSummary([9, 8, 7, 6, 5, 4, 3, 2, 1], elapsed: 90), accented: true).value,
                       "C0 10%, C1 9%, C2 8%, C3 7%, 5 more 16%, Unlogged 50%", "without colour it reads what is drawn")
    }

    @MainActor
    func testTheGalleryNameAndDescription() {
        XCTAssertEqual(LKey.categoryGauge.text(for: .english), "Category Gauge")
        XCTAssertEqual(LKey.categoryGauge.text(for: .chinese), "类别仪表")
        XCTAssertEqual(LKey.categoryGaugeDescription.text(for: .english),
                       "Your time by category as a gauge — no numbers, just color.")
        XCTAssertEqual(LKey.categoryGaugeDescription.text(for: .chinese), "用仪表盘的样子看各类别的时间占比，不显示文字。")
    }
}

// MARK: - Rendered

/// The gauge rendered with `ImageRenderer` at the small family's content
/// boxes (the boxes `CategoryStatsRenderTests` uses), measured rather than
/// looked at (`reference_widget_render_harness`).
@MainActor
final class CategoryGaugeRenderTests: XCTestCase {
    static let boxes = [CGSize(width: 116, height: 116), CGSize(width: 126, height: 126), CGSize(width: 138, height: 138)]

    private static func contents() -> [(String, CategoryStatsSummary)] {
        [
            ("sample", CategoryStatsLayout.sample(.week, chinese: false)),
            ("sampleElapsed", CategoryStatsLayout.sample(.month, basis: .elapsed, chinese: false)),
            ("nine", gaugeSummary([9, 8, 7, 6, 5, 4, 3, 2, 1])),
            ("nineElapsed", gaugeSummary([9, 8, 7, 6, 5, 4, 3, 2, 1], elapsed: 90)),
            ("one", gaugeSummary([3.5], period: .today)),
            ("sliver", gaugeSummary([40, 0.05], colors: false)),
            ("empty", CategoryStatsSummary(period: .week, status: .empty, categories: [], totalHours: 0)),
            ("elapsedNothing", gaugeSummary([], elapsed: 14, period: .today)),
        ]
    }

    private struct Canvas {
        var bytes: [UInt8]
        var width: Int
        var height: Int
        var scale: CGFloat

        func pixel(at point: CGPoint) -> [Double] {
            let base = (Int(point.y * scale) * width + Int(point.x * scale)) * 4
            return (0..<4).map { Double(bytes[base + $0]) / 255 }
        }
    }

    private func render<V: View>(_ view: V, box: CGSize, scale: CGFloat, dark: Bool, margin: CGFloat = 0) throws -> Canvas {
        let renderer = ImageRenderer(content: view.frame(width: box.width, height: box.height)
            .environment(\.colorScheme, dark ? .dark : .light)
            .padding(margin))
        renderer.scale = scale
        let image = try XCTUnwrap(renderer.cgImage)
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        _ = bytes.withUnsafeMutableBytes { buffer in
            CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?
                .draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return Canvas(bytes: bytes, width: w, height: h, scale: scale)
    }

    private struct Ink {
        var beyondBox: CGFloat = 0
        var offArc = 0
        var onArc = 0
    }

    /// Ink past the box, and ink inside the box but off the arc's stroke
    /// (its band, closed by round caps): anything not the arc — a glyph, a
    /// dot in the middle — lands off it.
    private func ink<V: View>(_ view: V, box: CGSize, scale: CGFloat, dark: Bool) throws -> Ink {
        let margin: CGFloat = 24
        let canvas = try render(view, box: box, scale: scale, dark: dark, margin: margin)
        let fit = CategoryGaugeLayout.fit(in: box)
        let inset = CategoryGaugeLayout.capInset(lineWidth: fit.lineWidth, radius: fit.radius)
        let ends = [135 + inset, 405 - inset].map { degrees in
            CGPoint(x: fit.center.x + fit.radius * cos(degrees * .pi / 180),
                    y: fit.center.y + fit.radius * sin(degrees * .pi / 180))
        }
        let slack = 1.5 / scale
        var result = Ink()
        for y in 0..<canvas.height {
            for x in 0..<canvas.width where canvas.bytes[(y * canvas.width + x) * 4 + 3] > 8 {
                let px = CGFloat(x), py = CGFloat(y)
                let left = margin * scale, top = margin * scale
                let right = (margin + box.width) * scale, bottom = (margin + box.height) * scale
                let dx = max(left - (px + 1), px - right + 1, 0), dy = max(top - (py + 1), py - bottom + 1, 0)
                result.beyondBox = max(result.beyondBox, max(dx, dy) / scale)
                let p = CGPoint(x: (px + 0.5) / scale - margin, y: (py + 0.5) / scale - margin)
                let d = hypot(p.x - fit.center.x, p.y - fit.center.y)
                var angle = atan2(p.y - fit.center.y, p.x - fit.center.x) * 180 / .pi
                if angle < 135 - 1e-9 { angle += 360 }
                let inBand = abs(d - fit.radius) <= fit.lineWidth / 2 + slack
                    && angle >= 135 + inset && angle <= 405 - inset
                let inCap = ends.contains { hypot(p.x - $0.x, p.y - $0.y) <= fit.lineWidth / 2 + slack }
                if inBand || inCap { result.onArc += 1 } else { result.offArc += 1 }
            }
        }
        return result
    }

    func testNothingButTheArcIsDrawnAndNothingPastTheBox() throws {
        var renders = 0
        for (name, summary) in Self.contents() {
            for box in Self.boxes {
                for (scale, dark, accented) in [(CGFloat(2), false, false), (3, false, false), (3, true, false),
                                                (3, false, true), (3, true, true)] {
                    let measured = try ink(CategoryGaugeWidgetView(summary: summary, accented: accented),
                                           box: box, scale: scale, dark: dark)
                    let label = "\(name) \(Int(box.width)) @\(Int(scale))x dark \(dark) accented \(accented)"
                    XCTAssertLessThanOrEqual(measured.beyondBox, 1 / scale + 1e-6, "\(label): past the box")
                    XCTAssertEqual(measured.offArc, 0, "\(label): ink off the arc")
                    XCTAssertGreaterThan(measured.onArc, Int(box.width * box.width * scale * scale * 0.2), "\(label): drew little")
                    renders += 1
                }
            }
        }
        XCTAssertEqual(renders, Self.contents().count * Self.boxes.count * 5)
    }

    /// The control: a percent in the middle, a word below, and a stray dot
    /// in the gap are each seen off the arc.
    func testControlTextIsSeenOffTheArc() throws {
        let summary = CategoryStatsLayout.sample(.week, chinese: false)
        let box = Self.boxes[0]
        let middle = ZStack {
            CategoryGaugeWidgetView(summary: summary, accented: false)
            Text("42%").font(.system(size: 15, weight: .bold))
        }
        let below = ZStack(alignment: .bottom) {
            CategoryGaugeWidgetView(summary: summary, accented: false)
            Text("Week").font(.system(size: 9))
        }
        XCTAssertGreaterThan(try ink(middle, box: box, scale: 3, dark: false).offArc, 50)
        XCTAssertGreaterThan(try ink(below, box: box, scale: 3, dark: false).offArc, 20)
        let shifted = CategoryGaugeWidgetView(summary: summary, accented: false).offset(y: 2)
        XCTAssertGreaterThan(try ink(shifted, box: box, scale: 3, dark: false).offArc, 50)
    }

    private func middles(_ summary: CategoryStatsSummary, box: CGSize,
                         accented: Bool = false) -> [(CategoryGaugeSegment, CGPoint)] {
        let fit = CategoryGaugeLayout.fit(in: box)
        let segments = CategoryGaugeLayout.segments(
            CategoryGaugeLayout.rows(summary, accented: accented),
            gap: CategoryGaugeLayout.degrees(points: CategoryGaugeLayout.jointGap, radius: fit.radius),
            minimum: CategoryGaugeLayout.degrees(points: CategoryGaugeLayout.minimumInk, radius: fit.radius))
        return segments.map { segment in
            let angle = (segment.start + segment.end) / 2 * .pi / 180
            return (segment, CGPoint(x: fit.center.x + fit.radius * cos(angle), y: fit.center.y + fit.radius * sin(angle)))
        }
    }

    /// In full colour each segment is its category's colour, in the rows'
    /// order; the remainder is the faces' remainder grey; the unlogged time
    /// and the empty gauge are the track.
    func testEachSegmentWearsItsRowsColour() throws {
        let box = Self.boxes[1]
        let empty = CategoryStatsSummary(period: .week, status: .empty, categories: [], totalHours: 0)
        for dark in [false, true] {
            for summary in [gaugeSummary([9, 8, 7, 6, 5, 4, 3, 2, 1]), gaugeSummary([9, 8, 7, 6, 5, 4, 3, 2, 1], elapsed: 90)] {
                let canvas = try render(CategoryGaugeWidgetView(summary: summary, accented: false), box: box, scale: 2, dark: dark)
                let emptyCanvas = try render(CategoryGaugeWidgetView(summary: empty, accented: false), box: box, scale: 2,
                                             dark: dark)
                let probes = middles(summary, box: box)
                XCTAssertEqual(probes.count, summary.basis == .elapsed ? 8 : 7)
                for (segment, point) in probes {
                    let seen = canvas.pixel(at: point)
                    let label = "\(segment.role) dark \(dark) basis \(summary.basis)"
                    switch segment.role {
                    case .category:
                        let c = try XCTUnwrap(CategoryStatsLayout.rgba(hex: try XCTUnwrap(segment.row?.colorHex)))
                        XCTAssertEqual(seen[0], c.red, accuracy: 3 / 255, label)
                        XCTAssertEqual(seen[1], c.green, accuracy: 3 / 255, label)
                        XCTAssertEqual(seen[2], c.blue, accuracy: 3 / 255, label)
                        XCTAssertEqual(seen[3], 1, accuracy: 1 / 255, label)
                    case .remainder:
                        let white = CategoryStatsLayout.remainderWhite(dark: dark)
                        for channel in 0..<3 { XCTAssertEqual(seen[channel], white, accuracy: 3 / 255, label) }
                        XCTAssertEqual(seen[3], 1, accuracy: 1 / 255, label)
                    case .track:
                        let track = emptyCanvas.pixel(at: point)
                        for channel in 0..<4 { XCTAssertEqual(seen[channel], track[channel], accuracy: 1.5 / 255, label) }
                        XCTAssertGreaterThan(track[3], 0.02, "the track shows")
                        XCTAssertLessThan(track[3], 0.5, "and is faint")
                    }
                }
            }
        }
    }

    /// Without colour every segment drawn is strictly fainter than the one
    /// before it — read off the render, so no two segments share a tone —
    /// with more categories than the ladder has rungs; the elapsed track
    /// fainter still. Four categories and a remainder, whatever the count.
    func testTheAccentedGaugeFallsWithEverySegment() throws {
        let box = Self.boxes[1]
        for count in [5, 6, 7, 8, 12] {
            let hours = (0..<count).map { Double(20 - $0) }
            for elapsed in [nil, 400.0] {
                for dark in [false, true] {
                    let summary = gaugeSummary(hours, elapsed: elapsed)
                    let canvas = try render(CategoryGaugeWidgetView(summary: summary, accented: true), box: box,
                                            scale: 2, dark: dark)
                    let probes = middles(summary, box: box, accented: true)
                    let label = "\(count) categories elapsed \(elapsed != nil) dark \(dark)"
                    let drawn = probes.filter { $0.0.role != .track }
                    XCTAssertEqual(drawn.count, count > 5 ? 5 : count, label)
                    if count > 5 { XCTAssertEqual(drawn.last?.0.role, .remainder, label) }
                    let tones = probes.map { canvas.pixel(at: $0.1)[3] }
                    for (index, (a, b)) in zip(tones, tones.dropFirst()).enumerated() {
                        XCTAssertGreaterThan(a - b, 0.03, "\(label): segment \(index + 1) is not fainter: \(tones)")
                    }
                    XCTAssertEqual(tones.first ?? 0, 1, accuracy: 0.02, "\(label): the leader is solid")
                }
            }
        }
    }

    /// The joints are background: a point on the centre line in the middle
    /// of each gap is clear.
    func testTheJointsAreGaps() throws {
        let box = Self.boxes[0]
        let summary = gaugeSummary([9, 8, 7, 6, 5, 4, 3, 2, 1], elapsed: 90)
        let canvas = try render(CategoryGaugeWidgetView(summary: summary, accented: false), box: box, scale: 3, dark: false)
        let fit = CategoryGaugeLayout.fit(in: box)
        let segments = middles(summary, box: box).map(\.0)
        for (a, b) in zip(segments, segments.dropFirst()) {
            let angle = (a.end + b.start) / 2 * .pi / 180
            for radius in [fit.radius - fit.lineWidth / 4, fit.radius, fit.radius + fit.lineWidth / 4] {
                let point = CGPoint(x: fit.center.x + radius * cos(angle), y: fit.center.y + radius * sin(angle))
                XCTAssertLessThan(canvas.pixel(at: point)[3], 0.35, "joint after \(a.role)")
            }
        }
    }

    /// The arc's two ends are round: a degree in from either end, the
    /// stroke's centre line is inked and its outer and inner edges are clear.
    func testTheEndsAreRound() throws {
        for box in Self.boxes {
            for summary in [gaugeSummary([6, 3, 1]), gaugeSummary([6, 3, 1], elapsed: 40)] {
                let canvas = try render(CategoryGaugeWidgetView(summary: summary, accented: false), box: box, scale: 3,
                                        dark: false)
                let fit = CategoryGaugeLayout.fit(in: box)
                for degrees in [136.0, 404.0] {
                    let angle = degrees * .pi / 180
                    func at(_ radius: CGFloat) -> Double {
                        canvas.pixel(at: CGPoint(x: fit.center.x + radius * cos(angle),
                                                 y: fit.center.y + radius * sin(angle)))[3]
                    }
                    let label = "\(Int(box.width)) \(summary.basis) at \(degrees)°"
                    XCTAssertGreaterThan(at(fit.radius), 0.02, "\(label): the centre line reaches the end")
                    XCTAssertLessThan(at(fit.radius + fit.lineWidth * 0.45), 0.01, "\(label): outer corner")
                    XCTAssertLessThan(at(fit.radius - fit.lineWidth * 0.45), 0.01, "\(label): inner corner")
                }
            }
        }
    }

    /// Writes the gauge's PNGs for a look by eye when `GAUGE_PNG_DIR` is set.
    func testWritePreviewsWhenAsked() throws {
        guard let dir = ProcessInfo.processInfo.environment["GAUGE_PNG_DIR"] else { throw XCTSkip("GAUGE_PNG_DIR unset") }
        let cases: [(String, CategoryStatsSummary, Bool, Bool)] = [
            ("logged-light", CategoryStatsLayout.sample(.week, chinese: false), false, false),
            ("logged-dark", CategoryStatsLayout.sample(.week, chinese: false), true, false),
            ("elapsed-light", CategoryStatsLayout.sample(.week, basis: .elapsed, chinese: false), false, false),
            ("elapsed-dark", CategoryStatsLayout.sample(.week, basis: .elapsed, chinese: false), true, false),
            ("nine-accented-dark", gaugeSummary([9, 8, 7, 6, 5, 4, 3, 2, 1]), true, true),
            ("empty-light", CategoryStatsSummary(period: .week, status: .empty, categories: [], totalHours: 0), false, false),
        ]
        for (name, summary, dark, accented) in cases {
            let view = CategoryGaugeWidgetView(summary: summary, accented: accented)
                .frame(width: 126, height: 126)
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 22).fill(dark ? Color(white: 0.11) : .white))
                .padding(8)
                .background(dark ? Color.black : Color(white: 0.85))
                .environment(\.colorScheme, dark ? .dark : .light)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 3
            let png = try XCTUnwrap(renderer.uiImage?.pngData())
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("gauge-\(name).png"))
        }
    }
}

// MARK: - Source

final class CategoryGaugeSourcePinTests: XCTestCase {
    private func code(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(path)
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    func testTheWidgetIsRegisteredAndSharesTheStatsWidgetsTimeline() throws {
        XCTAssertTrue(try code("DoneWidget/DoneWidgetBundle.swift").contains("CategoryGaugeWidget()"))
        let src = try code("DoneWidget/CategoryGaugeWidget.swift")
        for pin in ["let kind = \"DoneCategoryGaugeWidget\"",
                    "AppIntentConfiguration(kind: kind, intent: CategoryStatsConfigurationIntent.self, "
                        + "provider: CategoryStatsProvider())",
                    ".supportedFamilies([.systemSmall])",
                    ".configurationDisplayName(L(.categoryGauge))", ".description(L(.categoryGaugeDescription))",
                    "CategoryGaugeWidgetView(summary: entry.summary, accented: renderingMode != .fullColor)",
                    ".containerBackground(.background, for: .widget)"] {
            XCTAssertTrue(src.contains(pin), "missing: \(pin)")
        }
    }

    /// The gauge sets no text: nothing in its file can draw a glyph, and its
    /// colours come from the faces' own helpers.
    func testTheGaugeDrawsNoText() throws {
        let src = try code("Shared/CategoryGaugeWidgetView.swift")
        for drawer in ["Text", "Label", "Image", "Canvas"] {
            XCTAssertNil(src.range(of: "(^|[^A-Za-z0-9_.])\\(drawer)\\b", options: .regularExpression), drawer)
        }
        XCTAssertFalse(src.contains(".overlay"))
        XCTAssertNotNil(" Text(\"x\")".range(of: "(^|[^A-Za-z0-9_.])Text\\b", options: .regularExpression), "the scan sees a Text")
        XCTAssertTrue(src.contains("statsColor(row, accented: accented, dark: colorScheme == .dark, ranked: ranked)"))
        XCTAssertTrue(src.contains("guard let row = segment.row else { return statsTrack }"))
        XCTAssertTrue(src.contains(".widgetAccentable()"))
        XCTAssertTrue(src.contains(".accessibilityLabel(spoken.label)"))
        XCTAssertTrue(src.contains(".accessibilityValue(spoken.value)"))
    }
}
