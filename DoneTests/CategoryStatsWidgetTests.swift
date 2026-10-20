import XCTest
import SwiftUI
@testable import Done

// MARK: - Faces, rendered

/// Nothing a category-stats face draws may fall outside its content box: the
/// box is all WidgetKit shows, so ink past it is content the reader never
/// sees. The faces are rendered with `ImageRenderer` at the boxes the devices
/// hand them, on a transparent canvas larger than the box, and the ink past
/// the box is measured — not looked at (`reference_widget_render_harness`).
///
/// `ImageRenderer` is SwiftUI, not WidgetKit: this is the layout, not the
/// device. It does honour Bold Text (`legibilityWeight`) and the colour
/// scheme, which is what the matrix below varies.
@MainActor
final class CategoryStatsRenderTests: XCTestCase {
    private var savedLanguage: String??

    override func setUp() {
        super.setUp()
        savedLanguage = .some(UserDefaults.standard.string(forKey: AppSettingsLocale.languageKey))
    }

    override func tearDown() {
        if case .some(let value) = savedLanguage {
            if let value { UserDefaults.standard.set(value, forKey: AppSettingsLocale.languageKey) }
            else { UserDefaults.standard.removeObject(forKey: AppSettingsLocale.languageKey) }
        }
        super.tearDown()
    }

    private func setLanguage(_ code: String) {
        UserDefaults.standard.set(code, forKey: AppSettingsLocale.languageKey)
    }

    /// Content boxes: the small family's 116/126/138pt squares, the medium
    /// family's widths over the same heights. On the lock screen the system
    /// keeps a margin inside the widget's nominal size: the boxes are the one
    /// measured on the iPhone 17 simulator (iOS 26.4) as 148x58 with its ring
    /// 58 across, that measurement less 2pt, other devices' nominal sizes
    /// less the same margin, and the largest nominal size with no margin.
    static let boxes: [CategoryStatsFace: [CGSize]] = [
        .small: [CGSize(width: 116, height: 116), CGSize(width: 126, height: 126), CGSize(width: 138, height: 138)],
        .medium: [CGSize(width: 289, height: 116), CGSize(width: 306, height: 126), CGSize(width: 332, height: 138)],
        .rectangular: [CGSize(width: 140, height: 54), CGSize(width: 148, height: 56), CGSize(width: 148, height: 58),
                       CGSize(width: 160, height: 62), CGSize(width: 172, height: 76)],
        .circular: [CGSize(width: 54, height: 54), CGSize(width: 56, height: 56), CGSize(width: 58, height: 58),
                    CGSize(width: 62, height: 62), CGSize(width: 76, height: 76)],
    ]

    private static func summary(_ names: [String], hours: [Double], period: CategoryStatsPeriod = .week,
                                elapsed: Double? = nil) -> CategoryStatsSummary {
        let categories = zip(names, hours).map { CategoryHours(name: $0, colorHex: nil, hours: $1) }
        return CategoryStatsSummary(period: period, basis: elapsed == nil ? .logged : .elapsed, status: .ok,
                                    categories: CategoryStats.ranked(
                                        Dictionary(categories.map { ($0.name, $0.hours) }, uniquingKeysWith: +)
                                    ), totalHours: hours.reduce(0, +), elapsedHours: elapsed ?? 0)
    }

    /// Long names, more categories than any face lists, a literal "Other",
    /// a sliver under 1%, and a month's worth of hours in the header; then
    /// the elapsed basis: the same month a little over three weeks in, a day
    /// with nothing logged, and a day logged to the minute by one category.
    private static func contents(chinese: Bool) -> [(String, CategoryStatsSummary)] {
        let names = chinese
            ? ["行政事务与文书工作整理", "深度工作", "与设计团队开会讨论", "运动", "Other", "阅读", "茶歇"]
            : ["Administrative paperwork and email", "Deep Work", "Meetings with the design team", "Exercise",
               "Other", "Reading", "Tea"]
        let hours: [Double] = [61.5, 52.25, 48, 31, 27.5, 24.75, 0.4]
        return [
            ("seven", summary(names, hours: hours, period: .month)),
            ("one", summary([names[0]], hours: [3.5], period: .today)),
            ("five", summary(Array(names.prefix(5)), hours: Array(hours.prefix(5)))),
            ("empty", CategoryStatsSummary(period: .week, status: .empty, categories: [], totalHours: 0)),
            ("noData", CategoryStatsSummary(period: .month, status: .noData, categories: [], totalHours: 0)),
            ("stale", CategoryStatsSummary(period: .today, status: .stale, categories: [], totalHours: 0)),
            ("elapsedSeven", summary(names, hours: hours, period: .month, elapsed: 22.5 * 24)),
            ("elapsedNothing", summary([], hours: [], period: .today, elapsed: 14)),
            ("elapsedFull", summary([names[0]], hours: [14], period: .today, elapsed: 14)),
        ]
    }

    private struct Ink {
        /// How far past the box the ink reaches, in points (0 when none).
        var beyond: CGFloat
        /// Inked pixels inside the box.
        var inside: Int
    }

    private func ink<V: View>(_ view: V, box: CGSize, scale: CGFloat, bold: Bool, dark: Bool) throws -> Ink {
        let margin: CGFloat = 24
        let canvas = view
            .frame(width: box.width, height: box.height)
            .environment(\.legibilityWeight, bold ? .bold : .regular)
            .environment(\.colorScheme, dark ? .dark : .light)
            .padding(margin)
        let renderer = ImageRenderer(content: canvas)
        renderer.scale = scale
        let image = try XCTUnwrap(renderer.cgImage)
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        XCTAssertTrue(drawn)
        let left = margin * scale, top = margin * scale
        let right = (margin + box.width) * scale, bottom = (margin + box.height) * scale
        var result = Ink(beyond: 0, inside: 0)
        for y in 0..<h {
            for x in 0..<w where pixels[(y * w + x) * 4 + 3] > 24 {
                // Pixel (x, y) covers [x, x + 1); the box is [left, right).
                let px = CGFloat(x), py = CGFloat(y)
                let dx = max(left - (px + 1), px - right + 1, 0)
                let dy = max(top - (py + 1), py - bottom + 1, 0)
                let beyond = max(dx, dy) / scale
                if beyond > 0 { result.beyond = max(result.beyond, beyond) } else { result.inside += 1 }
            }
        }
        return result
    }

    /// One device pixel of antialiasing at the edge is tolerated, no more.
    private func tolerance(_ scale: CGFloat) -> CGFloat { 1 / scale + 1e-6 }

    func testNoFaceDrawsOutsideItsBox() throws {
        var renders = 0
        for language in ["en", "zh"] {
            setLanguage(language)
            for (name, summary) in Self.contents(chinese: language == "zh") {
                for face in CategoryStatsFace.allCases {
                    for box in Self.boxes[face]! {
                        // Light, full colour at both scales with Bold Text
                        // on and off; dark and accented at 3x.
                        let variants: [(scale: CGFloat, bold: Bool, dark: Bool, accented: Bool)] = [
                            (2, false, false, false), (2, true, false, false), (3, false, false, false),
                            (3, true, false, false), (3, true, true, false), (3, false, true, true), (3, true, false, true),
                        ]
                        for v in variants {
                            let view = CategoryStatsWidgetView(summary: summary, face: face, accented: v.accented)
                            let measured = try ink(view, box: box, scale: v.scale, bold: v.bold, dark: v.dark)
                            let label = "\(face) \(Int(box.width))x\(Int(box.height)) \(language) \(name) "
                                + "@\(Int(v.scale))x bold \(v.bold) dark \(v.dark) accented \(v.accented)"
                            XCTAssertLessThanOrEqual(measured.beyond, tolerance(v.scale), "\(label): ink \(measured.beyond)pt past the box")
                            XCTAssertGreaterThan(measured.inside, 50, "\(label): drew nothing")
                            renders += 1
                        }
                    }
                }
            }
        }
        XCTAssertEqual(renders, 2 * Self.contents(chinese: false).count * Self.boxes.values.reduce(0) { $0 + $1.count } * 7)
    }

    /// The face rendered whole, as bytes: premultiplied RGBA at `scale`.
    private func pixels<V: View>(_ view: V, box: CGSize, scale: CGFloat, bold: Bool, dark: Bool = false) throws -> [UInt8] {
        let renderer = ImageRenderer(content: view.frame(width: box.width, height: box.height)
            .environment(\.legibilityWeight, bold ? .bold : .regular)
            .environment(\.colorScheme, dark ? .dark : .light))
        renderer.scale = scale
        let image = try XCTUnwrap(renderer.cgImage)
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        _ = bytes.withUnsafeMutableBytes { buffer in
            CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?
                .draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return bytes
    }

    /// Whether any text the face draws, other than a category name, is cut
    /// short. A text that fits draws the same whether it would truncate at
    /// its head or its tail, and one that does not ("100…" against "…00%")
    /// draws differently: so the face is rendered both ways and compared.
    /// Category names are the one text a face lets truncate, and they set
    /// their own mode, which the environment cannot change.
    private func truncates<V: View>(_ view: V, box: CGSize, bold: Bool) throws -> Bool {
        let tail = try pixels(view.environment(\.truncationMode, .tail), box: box, scale: 3, bold: bold)
        let head = try pixels(view.environment(\.truncationMode, .head), box: box, scale: 3, bold: bold)
        return tail != head
    }

    /// Nothing but a category name is ever cut short — no percent, header,
    /// count, "Unlogged" or message — on any face, box or language, with
    /// Bold Text on or off. The ink test above cannot see this: a "100…"
    /// sits inside its box.
    func testNoFaceTruncatesAnythingButANameInAnyBox() throws {
        var checked = 0
        for language in ["en", "zh"] {
            setLanguage(language)
            for (name, summary) in Self.contents(chinese: language == "zh") {
                for face in CategoryStatsFace.allCases {
                    for box in Self.boxes[face]! {
                        for bold in [false, true] {
                            let view = CategoryStatsWidgetView(summary: summary, face: face, accented: false)
                            XCTAssertFalse(try truncates(view, box: box, bold: bold),
                                           "\(face) \(Int(box.width))x\(Int(box.height)) \(language) \(name) bold \(bold)")
                            checked += 1
                        }
                    }
                }
            }
        }
        XCTAssertEqual(checked, 2 * Self.contents(chinese: false).count * Self.boxes.values.reduce(0) { $0 + $1.count } * 2)
    }

    /// The comparison sees a truncation: the circular face's "100%" in a
    /// ring too small for it, and a header set in a box too narrow, both
    /// read as truncated; the same faces in their own boxes do not.
    func testControlATruncationIsSeen() throws {
        setLanguage("en")
        let one = Self.contents(chinese: false)[1].1
        XCTAssertTrue(try truncates(CategoryStatsWidgetView(summary: one, face: .circular, accented: false),
                                    box: CGSize(width: 34, height: 34), bold: true))
        XCTAssertFalse(try truncates(CategoryStatsWidgetView(summary: one, face: .circular, accented: false),
                                     box: CGSize(width: 54, height: 54), bold: true))
        let seven = Self.contents(chinese: false)[0].1
        XCTAssertTrue(try truncates(CategoryStatsWidgetView(summary: seven, face: .small, accented: false),
                                    box: CGSize(width: 70, height: 138), bold: false))
    }

    /// A payload as round one wrote it, before the background list, draws
    /// on every face: its numbers with the option off, "Open Done to
    /// refresh" with it on — inside the box and whole, either way.
    func testARoundOnePayloadStillRenders() throws {
        setLanguage("en")
        let payload = try JSONDecoder().decode(CategoryStatsPayload.self,
                                               from: Data(CategoryStatsFixtures.roundOnePayload.utf8))
        let noon = try XCTUnwrap(payload.days?.first?.start).addingTimeInterval(12 * 3600)
        let off = CategoryStats.summary(of: payload, options: CategoryStatsOptions(period: .today), asOf: noon)
        let on = CategoryStats.summary(of: payload, options: CategoryStatsOptions(period: .today, excludesBackground: true),
                                       asOf: noon)
        XCTAssertEqual(off.status, .ok)
        XCTAssertEqual(on.status, .stale)
        XCTAssertEqual(LFormat.statsMessage(on.status, period: on.period), "Open Done to refresh")
        for summary in [off, on] {
            for face in CategoryStatsFace.allCases {
                let box = Self.boxes[face]![0]
                let view = CategoryStatsWidgetView(summary: summary, face: face, accented: false)
                let measured = try ink(view, box: box, scale: 3, bold: false, dark: false)
                XCTAssertLessThanOrEqual(measured.beyond, tolerance(3), "\(face) \(summary.status)")
                XCTAssertGreaterThan(measured.inside, 50, "\(face) \(summary.status)")
                XCTAssertFalse(try truncates(view, box: box, bold: false), "\(face) \(summary.status)")
            }
        }
    }

    /// The circular face's percent at its largest, "100%", whole in every
    /// ring, Bold Text on and off, in both languages.
    func testTheRingsHundredPercentFitsEveryRing() throws {
        for language in ["en", "zh"] {
            setLanguage(language)
            let one = Self.contents(chinese: language == "zh")[1].1
            XCTAssertEqual(CategoryStats.breakdown(one.categories, maxRows: 1).first?.percentText, "100%")
            for box in Self.boxes[.circular]! {
                for bold in [false, true] {
                    XCTAssertFalse(try truncates(CategoryStatsWidgetView(summary: one, face: .circular, accented: false),
                                                 box: box, bold: bold), "\(language) \(box) bold \(bold)")
                }
            }
        }
    }

    /// The gallery's small face is the preview the user picked, and every
    /// small box draws all four of its rows, in both languages, Bold Text on
    /// and off. Its last row is the count row, never a bare "其他".
    func testTheGallerySampleIsThePickedPreviewDrawnInFull() throws {
        for language in ["en", "zh"] {
            setLanguage(language)
            let sample = CategoryStatsLayout.sample(.week, chinese: language == "zh")
            let rows = CategoryStats.breakdown(sample.categories, maxRows: CategoryStatsLayout.rowCap(.small))
            XCTAssertEqual(rows.map(\.percent), [42, 25, 10, 23], language)
            XCTAssertEqual(rows.last?.kind, .remainder(count: 3), language)
            for box in Self.boxes[.small]! {
                for bold in [false, true] {
                    XCTAssertEqual(try rowsDrawn(CategoryStatsWidgetView(summary: sample, face: .small, accented: false),
                                                 box: box, bold: bold), 4, "\(language) \(box) bold \(bold)")
                }
            }
        }
        setLanguage("zh")
        let zh = CategoryStatsLayout.sample(.week, chinese: true)
        XCTAssertEqual(LFormat.statsHeader(zh.period, hours: zh.totalHours), "本周 · 32.5 小时")
        XCTAssertEqual(CategoryStats.breakdown(zh.categories, maxRows: 4).prefix(3).map(\.name), ["深度工作", "会议", "运动"])
        XCTAssertEqual(LFormat.statsRemainder(3), "其余 3 类")
    }

    /// Alpha of the pixel at `point` (in points) of a view rendered at
    /// `scale` on a transparent canvas, 0...1.
    private func alpha<V: View>(_ view: V, size: CGSize, scale: CGFloat, at points: [CGPoint]) throws -> [Double] {
        let bytes = try pixels(view, box: size, scale: scale, bold: false)
        let w = Int((size.width * scale).rounded())
        return points.map { point in
            let x = Int(point.x * scale), y = Int(point.y * scale)
            return Double(bytes[(y * w + x) * 4 + 3]) / 255
        }
    }

    /// The three markers are three shapes: a category's dot is filled at its
    /// centre, the remainder's ring is hollow there, and the unlogged row's
    /// is a short bar — inked at the centre, nothing above or below it.
    func testTheRowMarkersAreThreeShapes() throws {
        let size = CGSize(width: CategoryStatsLayout.dotSize, height: CategoryStatsLayout.dotSize)
        let half = CategoryStatsLayout.dotSize / 2
        let probes = [CGPoint(x: half, y: half), CGPoint(x: half, y: 0.6), CGPoint(x: 0.6, y: half)]
        let category = CategoryStatsRow(kind: .category(rank: 0), name: "A", colorHex: "#FF0000", hours: 1, share: 1, percent: 100)
        let remainder = CategoryStatsRow(kind: .remainder(count: 2), name: "", hours: 1, share: 1, percent: 100)
        let unlogged = CategoryStatsRow(kind: .unlogged, name: "", hours: 1, share: 1, percent: 100)
        for accented in [false, true] {
            let dot = try alpha(StatsDot(row: category, accented: accented), size: size, scale: 8, at: probes)
            let ring = try alpha(StatsDot(row: remainder, accented: accented), size: size, scale: 8, at: probes)
            let bar = try alpha(StatsDot(row: unlogged, accented: accented), size: size, scale: 8, at: probes)
            // centre, top edge, left edge
            XCTAssertGreaterThan(dot[0], 0.9, "the dot is filled (accented \(accented))")
            XCTAssertGreaterThan(dot[1], 0.3); XCTAssertGreaterThan(dot[2], 0.3)
            XCTAssertLessThan(ring[0], 0.05, "the ring is hollow (accented \(accented))")
            XCTAssertGreaterThan(ring[1], 0.3); XCTAssertGreaterThan(ring[2], 0.3)
            XCTAssertGreaterThan(bar[0], 0.2, "the bar is inked at the centre (accented \(accented))")
            XCTAssertLessThan(bar[1], 0.05, "and not above it")
            XCTAssertGreaterThan(bar[2], 0.1, "and runs the marker's width")
        }
    }

    /// Without colour the bar's segments fall in opacity with rank, the
    /// remainder on the rung after the ranked categories and the unlogged
    /// track fainter still — read off the rendered bar at each segment's
    /// middle.
    func testTheAccentedBarFallsWithRank() throws {
        let categories = (0..<6).map { CategoryHours(name: "C\($0)", hours: Double(12 - $0)) }
        let rows = CategoryStats.breakdown(categories, maxRows: 6, unlogged: 20)
        XCTAssertEqual(rows.map(\.kind), [.category(rank: 0), .category(rank: 1), .category(rank: 2), .category(rank: 3),
                                          .remainder(count: 2), .unlogged])
        let size = CGSize(width: 300, height: 8)
        let gap = CategoryStatsLayout.barGap(accented: true)
        let widths = CategoryStatsLayout.segmentWidths(rows.map(\.share), width: size.width, gap: gap,
                                                        minimum: CategoryStatsLayout.minimumSegment)
        var x: CGFloat = 0
        var middles: [CGPoint] = []
        for width in widths {
            middles.append(CGPoint(x: x + width / 2, y: size.height / 2))
            x += width + gap
        }
        let read = try alpha(StatsBar(rows: rows, accented: true), size: size, scale: 2, at: middles)
        let expected = (0..<4).map { CategoryStatsLayout.accentedOpacity(rank: $0) }
            + [CategoryStatsLayout.remainderAccentedOpacity(after: 4)]
        XCTAssertLessThan(expected[4], expected[3], "the remainder is fainter than every ranked category")
        for (index, value) in expected.enumerated() {
            XCTAssertEqual(read[index], value, accuracy: 0.02, "segment \(index)")
        }
        XCTAssertGreaterThan(read[5], 0.02, "the unlogged track shows")
        XCTAssertLessThan(read[5], read[4], "and is fainter than the remainder")
    }

    /// WCAG relative luminance of an sRGB colour, components 0...1.
    private func luminance(_ rgb: [Double]) -> Double {
        let linear = rgb.map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
    }

    private func contrast(_ a: Double, _ b: Double) -> Double { (max(a, b) + 0.05) / (min(a, b) + 0.05) }

    /// Premultiplied RGBA, 0...1, at each of `points` (in points) of a view
    /// rendered at `scale` on a transparent canvas.
    private func rgba<V: View>(_ view: V, size: CGSize, scale: CGFloat, dark: Bool, at points: [CGPoint]) throws -> [[Double]] {
        let bytes = try pixels(view, box: size, scale: scale, bold: false, dark: dark)
        let w = Int((size.width * scale).rounded())
        return points.map { point in
            let base = (Int(point.y * scale) * w + Int(point.x * scale)) * 4
            return (0..<4).map { Double(bytes[base + $0]) / 255 }
        }
    }

    /// What a pixel looks like on a face: in full colour over the widget's
    /// background, white in the light scheme and black in the dark; without
    /// colour, where the system keeps only how opaque the ink is, as white
    /// at that opacity over black.
    private func seen(_ pixel: [Double], dark: Bool, accented: Bool) -> Double {
        if accented { return luminance([pixel[3], pixel[3], pixel[3]]) }
        let background: Double = dark ? 0 : 1
        return luminance((0..<3).map { pixel[$0] + background * (1 - pixel[3]) })
    }

    /// The elapsed bar's rows as each face's bar takes them, over a span
    /// with unlogged time in it, and each segment's middle.
    private func elapsedBars() -> [(label: String, rows: [CategoryStatsRow], middles: (Bool) -> [CGPoint])] {
        let categories = [10.0, 9, 8, 7, 6, 5, 4].enumerated().map { CategoryHours(name: "C\($0)", hours: $1) }
        var bars: [(label: String, rows: [CategoryStatsRow], middles: (Bool) -> [CGPoint])] = []
        for face in [CategoryStatsFace.small, .medium, .rectangular] {
            for count in 1...categories.count {
                let rows = CategoryStats.breakdown(Array(categories.prefix(count)), maxRows: CategoryStatsLayout.barCap(face),
                                                   unlogged: 30)
                bars.append(("\(face) \(count) categories", rows, { accented in
                    let gap = CategoryStatsLayout.barGap(accented: accented)
                    let widths = CategoryStatsLayout.segmentWidths(rows.map(\.share), width: 300, gap: gap,
                                                                    minimum: CategoryStatsLayout.minimumSegment)
                    var x: CGFloat = 0
                    return widths.map { width in
                        defer { x += width + gap }
                        return CGPoint(x: x + width / 2, y: 4)
                    }
                }))
            }
        }
        return bars
    }

    /// In the elapsed basis the unlogged part of the bar is its track, and
    /// the time logged has to read as filled beside it: every logged segment
    /// stands out from the track by at least the 3:1 WCAG asks of a
    /// component against what is next to it — without colour every one of
    /// them, since opacity is all that tells them from the track; in full
    /// colour the remainder, the one grey among the colours, in both
    /// schemes. Each face's bar, with one category up to more than it lists.
    func testEveryLoggedSegmentStandsOutFromTheTrack() throws {
        let size = CGSize(width: 300, height: 8)
        var checked = 0
        for bar in elapsedBars() {
            XCTAssertEqual(bar.rows.last?.kind, .unlogged, bar.label)
            for (accented, dark) in [(true, false), (false, false), (false, true)] {
                let read = try rgba(StatsBar(rows: bar.rows, accented: accented), size: size, scale: 2, dark: dark,
                                    at: bar.middles(accented))
                let track = seen(read[read.count - 1], dark: dark, accented: accented)
                for (index, row) in bar.rows.enumerated() where !row.isUnlogged && (accented || row.isRemainder) {
                    let ratio = contrast(seen(read[index], dark: dark, accented: accented), track)
                    XCTAssertGreaterThanOrEqual(ratio, 3, "\(bar.label), \(row.kind), accented \(accented) dark \(dark): "
                                                + "\(String(format: "%.2f", ratio)):1 against the track")
                    checked += 1
                }
            }
        }
        XCTAssertGreaterThan(checked, 60, "positive control: the remainders and ranks were reached")
    }

    /// The measure can fail: a segment as faint as the remainder was drawn
    /// before — 0.18 without colour, a 45% grey in full colour — reads under
    /// 3:1 against the track.
    func testControlAFaintSegmentIsSeen() throws {
        let size = CGSize(width: 20, height: 8)
        let middle = [CGPoint(x: 10, y: 4)]
        let track = try rgba(StatsBar(rows: [], accented: true), size: size, scale: 2, dark: false, at: middle)[0]
        let faint = try rgba(Rectangle().fill(Color.primary.opacity(0.18)), size: size, scale: 2, dark: false, at: middle)[0]
        XCTAssertLessThan(contrast(seen(faint, dark: false, accented: true), seen(track, dark: false, accented: true)), 3)
        let grey = try rgba(Rectangle().fill(Color.secondary.opacity(0.45)), size: size, scale: 2, dark: false, at: middle)[0]
        XCTAssertLessThan(contrast(seen(grey, dark: false, accented: false), seen(track, dark: false, accented: false)), 3)
    }

    /// The unlogged part of the bar is drawn exactly as the track an empty
    /// bar shows — with colour and without, light and dark — never in a
    /// colour a category could have.
    func testTheUnloggedPartIsTheTrack() throws {
        let size = CGSize(width: 300, height: 8)
        for bar in elapsedBars() {
            for (accented, dark) in [(true, false), (false, false), (false, true)] {
                let point = bar.middles(accented).last!
                let unlogged = try rgba(StatsBar(rows: bar.rows, accented: accented), size: size, scale: 2, dark: dark,
                                        at: [point])[0]
                let empty = try rgba(StatsBar(rows: [], accented: accented), size: size, scale: 2, dark: dark, at: [point])[0]
                for channel in 0..<4 {
                    XCTAssertEqual(unlogged[channel], empty[channel], accuracy: 1.5 / 255,
                                   "\(bar.label) accented \(accented) dark \(dark): \(unlogged) vs the track \(empty)")
                }
            }
        }
    }

    /// In the elapsed basis the ring is the leader's share of the elapsed
    /// span, drawn as the logged basis draws a leader with the same share:
    /// six hours of a ten-hour day, against six of ten logged, is one ring —
    /// arc, percent and name — in every box, with colour and without. With
    /// nothing logged it is the leaderless ring ("--"), which differs.
    func testTheElapsedRingDrawsItsLeaderAsTheLoggedRingWould() throws {
        setLanguage("en")
        let leader = CategoryHours(name: "Deep Work", colorHex: "#5E5CE6", hours: 6)
        let elapsed = CategoryStatsSummary(period: .today, basis: .elapsed, status: .ok,
                                           categories: [leader, CategoryHours(name: "Reading", colorHex: "#0A84FF", hours: 1)],
                                           totalHours: 7, elapsedHours: 10)
        let logged = CategoryStatsSummary(period: .today, basis: .logged, status: .ok,
                                          categories: [leader, CategoryHours(name: "Meetings", colorHex: "#FF9F0A", hours: 4)],
                                          totalHours: 10)
        let nothing = CategoryStatsSummary(period: .today, basis: .elapsed, status: .ok, categories: [], totalHours: 0,
                                           elapsedHours: 10)
        XCTAssertEqual(CategoryStatsLayout.ringLeader(elapsed)?.percentText, "60%")
        XCTAssertEqual(CategoryStatsLayout.ringLeader(logged)?.percentText, "60%")
        XCTAssertNil(CategoryStatsLayout.ringLeader(nothing))
        for box in Self.boxes[.circular]! {
            for accented in [false, true] {
                let a = try pixels(CategoryStatsWidgetView(summary: elapsed, face: .circular, accented: accented),
                                   box: box, scale: 3, bold: false)
                let b = try pixels(CategoryStatsWidgetView(summary: logged, face: .circular, accented: accented),
                                   box: box, scale: 3, bold: false)
                let none = try pixels(CategoryStatsWidgetView(summary: nothing, face: .circular, accented: accented),
                                      box: box, scale: 3, bold: false)
                XCTAssertEqual(a, b, "\(box) accented \(accented)")
                XCTAssertNotEqual(a, none, "control: \(box) accented \(accented)")
            }
        }
    }

    /// The measurement can see an overflow: a label set wider than its box
    /// reads as ink past the edge.
    func testControlAnOverflowIsMeasured() throws {
        let overflowing = Text("Administrative paperwork and email")
            .font(.system(size: 13, weight: .semibold))
            .fixedSize()
            .frame(width: 60, height: 20)
        let measured = try ink(overflowing, box: CGSize(width: 60, height: 20), scale: 3, bold: false, dark: false)
        XCTAssertGreaterThan(measured.beyond, 20)
    }

    /// Rows a face drew, counted from the right edge below the bar, where
    /// every row ends in its percent: the inked runs down a 4pt band at the
    /// right edge — runs under 4pt apart being one glyph, a "%" — under the
    /// first pixel row inked across most of the width, the bar. (A header
    /// can reach the right edge too; it is above the bar.)
    private func rowsDrawn<V: View>(_ view: V, box: CGSize, bold: Bool) throws -> Int {
        let scale: CGFloat = 3
        let renderer = ImageRenderer(content: view.frame(width: box.width, height: box.height)
            .environment(\.legibilityWeight, bold ? .bold : .regular))
        renderer.scale = scale
        let image = try XCTUnwrap(renderer.cgImage)
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        _ = pixels.withUnsafeMutableBytes { buffer in
            CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?
                .draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        let wide = (0..<h).first { y in (0..<w).filter { x in pixels[(y * w + x) * 4 + 3] > 24 }.count * 10 >= w * 9 }
        let bar = try XCTUnwrap(wide, "no bar")
        let barEnd = (bar..<h).first { y in (0..<w).filter { x in pixels[(y * w + x) * 4 + 3] > 24 }.count * 10 < w * 9 } ?? h
        let band = (w - Int(4 * scale))..<w
        let inked = (0..<h).map { y in y >= barEnd && band.contains { x in pixels[(y * w + x) * 4 + 3] > 24 } }
        var runs = 0
        var lastInk = -Int.max / 2
        for y in 0..<h where inked[y] {
            if y - lastInk > Int(4 * scale) { runs += 1 }
            lastInk = y
        }
        return runs
    }

    /// How many rows each face keeps, by box, language and Bold Text, for
    /// the seven-category month in both bases (printed for the record):
    /// every face keeps its whole cap — the small face three leaders and the
    /// remainder, the medium four and the remainder, the lock screen two
    /// leaders; in the elapsed basis one fewer category and the unlogged row
    /// — in every box. Were a face ever to give a row up, the render test
    /// above is what says it did so inside the box.
    func testRowsKeptByFaceAndBox() throws {
        var table: [String] = []
        for language in ["en", "zh"] {
            setLanguage(language)
            let contents = Self.contents(chinese: language == "zh")
            for summary in [contents[0].1, contents[6].1] {
                for face in [CategoryStatsFace.small, .medium, .rectangular] {
                    for box in Self.boxes[face]! {
                        for bold in [false, true] {
                            let rows = try rowsDrawn(CategoryStatsWidgetView(summary: summary, face: face, accented: false),
                                                     box: box, bold: bold)
                            table.append("\(face) \(summary.basis) \(Int(box.width))x\(Int(box.height)) \(language) "
                                         + "bold=\(bold): \(rows)")
                            XCTAssertEqual(rows, CategoryStatsLayout.rowCap(face),
                                           "\(face) \(summary.basis) \(box) \(language) bold \(bold): \(rows) rows")
                        }
                    }
                }
            }
        }
        print("category-stats rows kept:\n" + table.joined(separator: "\n"))

        // Control: the count follows the content, it is not stuck at the cap.
        for face in [CategoryStatsFace.small, .medium, .rectangular] {
            let one = Self.contents(chinese: false)[1].1
            let box = Self.boxes[face]![0]
            XCTAssertEqual(try rowsDrawn(CategoryStatsWidgetView(summary: one, face: face, accented: false),
                                         box: box, bold: false), 1, "\(face)")
        }
    }
}

// MARK: - Layout arithmetic

final class CategoryStatsLayoutTests: XCTestCase {
    @MainActor
    func testSegmentsFillTheBarExactly() {
        for width in [CGFloat(84), 116, 289.5] {
            for gap in [CGFloat(1), 2] {
                for shares in [[0.5, 0.3, 0.2], [0.999, 0.0005, 0.0005], [1.0], [0.2, 0.2, 0.2, 0.2, 0.2, 0]] {
                    let widths = CategoryStatsLayout.segmentWidths(shares, width: width, gap: gap, minimum: 2)
                    XCTAssertEqual(widths.count, shares.count)
                    XCTAssertEqual(widths.reduce(0, +) + gap * CGFloat(shares.count - 1), width, accuracy: 1e-9)
                    for w in widths { XCTAssertGreaterThanOrEqual(w, 2 - 1e-9, "every segment shows") }
                    if shares.count > 1 {
                        XCTAssertGreaterThanOrEqual(widths[0], widths[1], "order and proportion kept")
                    }
                }
            }
        }
        // No room for the minimum: plain proportions, still exactly the width.
        let tight = CategoryStatsLayout.segmentWidths([0.9, 0.05, 0.05], width: 6, gap: 2, minimum: 2)
        XCTAssertEqual(tight.reduce(0, +), 2, accuracy: 1e-9)
        XCTAssertEqual(CategoryStatsLayout.segmentWidths([], width: 100, gap: 2, minimum: 2), [])
        XCTAssertEqual(CategoryStatsLayout.segmentWidths([0, 0], width: 100, gap: 2, minimum: 2), [0, 0])
    }

    /// The ladder falls with rank, and the remainder after `n` ranked
    /// categories stands on the rung after theirs: fainter than each of
    /// them, as faint as a category ranked where it stands would be.
    @MainActor
    func testTheAccentedLadderFallsWithRankAndTheRemainderTakesTheNextRung() {
        let ladder = (0..<6).map { CategoryStatsLayout.accentedOpacity(rank: $0) }
        for (a, b) in zip(ladder, ladder.dropFirst().prefix(4)) { XCTAssertGreaterThan(a, b) }
        XCTAssertEqual(ladder[0], 1)
        for ranked in 1..<5 {
            XCTAssertEqual(CategoryStatsLayout.remainderAccentedOpacity(after: ranked), ladder[ranked])
            XCTAssertLessThan(CategoryStatsLayout.remainderAccentedOpacity(after: ranked), ladder[ranked - 1])
        }
        XCTAssertGreaterThan(CategoryStatsLayout.barGap(accented: true), CategoryStatsLayout.barGap(accented: false))
    }

    @MainActor
    func testHexColours() throws {
        let c = try XCTUnwrap(CategoryStatsLayout.rgba(hex: "#FF8000"))
        XCTAssertEqual(c.red, 1); XCTAssertEqual(c.green, 128.0 / 255, accuracy: 1e-12); XCTAssertEqual(c.blue, 0)
        XCTAssertEqual(c.alpha, 1)
        XCTAssertEqual(try XCTUnwrap(CategoryStatsLayout.rgba(hex: " 00000080 ")).alpha, 128.0 / 255, accuracy: 1e-12)
        XCTAssertNil(CategoryStatsLayout.rgba(hex: "#FFF"))
        XCTAssertNil(CategoryStatsLayout.rgba(hex: "nothex"))
    }

    @MainActor
    func testRowCapsAreTheSpecifiedOnes() {
        XCTAssertEqual(CategoryStatsFace.allCases.map(CategoryStatsLayout.rowCap), [4, 5, 2, 1])
    }

    /// Each family the widget supports draws its own face.
    @MainActor
    func testEachFamilyDrawsItsOwnFace() {
        XCTAssertEqual(CategoryStatsFace(family: .systemSmall), .small)
        XCTAssertEqual(CategoryStatsFace(family: .systemMedium), .medium)
        XCTAssertEqual(CategoryStatsFace(family: .accessoryRectangular), .rectangular)
        XCTAssertEqual(CategoryStatsFace(family: .accessoryCircular), .circular)
    }

    /// The Edit Widget sheet's defaults: this week, share of logged time,
    /// background included (the intent's own defaults are pinned by source).
    @MainActor
    func testTheOptionsDefaultToTheWeeksLoggedTimeWithEverythingIn() {
        let options = CategoryStatsOptions()
        XCTAssertEqual(options.period, .week)
        XCTAssertEqual(options.basis, .logged)
        XCTAssertFalse(options.excludesBackground)
    }

    /// Each period's gallery sample is one that period could show: the
    /// preview's split at the day's, the week's and the month's scale, the
    /// day's hours well inside the part of a day its elapsed sample has had,
    /// the month more than the week, every elapsed span longer than what was
    /// logged in it and no longer than its period.
    @MainActor
    func testEachPeriodHasAPlausibleSample() {
        for chinese in [false, true] {
            let logged = CategoryStatsPeriod.allCases.map { CategoryStatsLayout.sample($0, chinese: chinese) }
            let elapsed = CategoryStatsPeriod.allCases.map { CategoryStatsLayout.sample($0, basis: .elapsed, chinese: chinese) }
            let longest: [Double] = [24, 7 * 24, 31 * 24]
            for (index, sample) in logged.enumerated() {
                XCTAssertEqual(CategoryStats.breakdown(sample.categories, maxRows: CategoryStatsLayout.rowCap(.small))
                    .map(\.percent), [42, 25, 10, 23], "\(sample.period)")
                XCTAssertEqual(sample.basis, .logged)
                XCTAssertEqual(sample.totalHours, sample.categories.reduce(0) { $0 + $1.hours }, accuracy: 1e-9)
                let span = elapsed[index]
                XCTAssertEqual(span.basis, .elapsed)
                XCTAssertEqual(span.categories, sample.categories)
                XCTAssertGreaterThan(span.elapsedHours, span.totalHours, "\(sample.period)")
                XCTAssertLessThanOrEqual(span.elapsedHours, longest[index], "\(sample.period)")
            }
            XCTAssertLessThan(logged[0].totalHours, elapsed[0].elapsedHours / 2, "the day's hours are well inside its day")
            XCTAssertLessThan(logged[0].totalHours, logged[1].totalHours)
            XCTAssertLessThan(logged[1].totalHours, logged[2].totalHours, "the month holds more than the week")
            let rows = CategoryStats.breakdown(elapsed[1].categories, maxRows: CategoryStatsLayout.rowCap(.small),
                                               unlogged: elapsed[1].unloggedHours)
            XCTAssertEqual(rows.last?.kind, .unlogged)
            XCTAssertEqual(rows.map(\.percent).reduce(0, +), 100)
        }
    }
}

// MARK: - Strings

final class CategoryStatsLocalizationTests: XCTestCase {
    private var savedLanguage: String??

    override func setUp() {
        super.setUp()
        savedLanguage = .some(UserDefaults.standard.string(forKey: AppSettingsLocale.languageKey))
    }

    override func tearDown() {
        if case .some(let value) = savedLanguage {
            if let value { UserDefaults.standard.set(value, forKey: AppSettingsLocale.languageKey) }
            else { UserDefaults.standard.removeObject(forKey: AppSettingsLocale.languageKey) }
        }
        super.tearDown()
    }

    private let keys: [LKey] = [
        .categoryStats, .categoryStatsDescFormat, .statsPeriodToday, .statsPeriodWeek, .statsPeriodMonth,
        .statsHeaderFormat, .statsHoursFormat, .statsRemainderFormat, .statsOpenToStart, .statsOpenToRefresh,
        .statsEmptyToday, .statsEmptyWeek, .statsEmptyMonth, .statsElapsedHeaderFormat, .statsUnlogged,
    ]

    @MainActor
    func testEveryKeyHasBothLanguages() {
        for key in keys {
            let en = key.text(for: .english), zh = key.text(for: .chinese)
            XCTAssertFalse(en.isEmpty, "\(key)")
            XCTAssertFalse(zh.isEmpty, "\(key)")
            if key != .statsHoursFormat {
                XCTAssertNotEqual(en, zh, "\(key) is untranslated")
            }
        }
        XCTAssertEqual(LKey.statsHoursFormat.text(for: .chinese), "%@h", "rows stay compact in both languages")
    }

    /// The description is what the gallery and the Edit Widget sheet show
    /// (the sheet shows no option's own description), so it is where the
    /// sheet can say where the list "Exclude background categories" reads is
    /// set — named by the labels the app shows on the way there.
    @MainActor
    func testTheGalleryNameAndDescription() {
        XCTAssertEqual(LKey.categoryStats.text(for: .english), "Time by Category")
        XCTAssertEqual(LKey.categoryStats.text(for: .chinese), "类别占比")
        UserDefaults.standard.set("en", forKey: AppSettingsLocale.languageKey)
        XCTAssertEqual(LFormat.categoryStatsDescription(), "How your recent time splits across categories. "
                       + "Background categories are the ones chosen under Me › Edit profile › Hide from Me tab.")
        UserDefaults.standard.set("zh", forKey: AppSettingsLocale.languageKey)
        XCTAssertEqual(LFormat.categoryStatsDescription(),
                       "最近一段时间里各类事件的时间占比。背景类别在「我 › 编辑资料 › 从 Me 标签隐藏」里选。")
        for language in ["en", "zh"] {
            UserDefaults.standard.set(language, forKey: AppSettingsLocale.languageKey)
            let description = LFormat.categoryStatsDescription()
            XCTAssertTrue(description.contains("\(L(.tabMe)) › \(L(.editProfile)) › \(L(.hideFromMeTab))"), description)
        }
    }

    /// A face's header says what its whole bar stands for: the hours logged,
    /// or in the elapsed basis the span elapsed, whatever was logged in it;
    /// the period alone when there are no numbers.
    @MainActor
    func testTheHeaderSaysWhatTheWholeBarIs() {
        for (language, chinese) in [("en", false), ("zh", true)] {
            UserDefaults.standard.set(language, forKey: AppSettingsLocale.languageKey)
            let logged = CategoryStatsLayout.sample(.week, chinese: chinese)
            var elapsed = CategoryStatsLayout.sample(.week, basis: .elapsed, chinese: chinese)
            XCTAssertEqual(categoryStatsHeader(logged), chinese ? "本周 · 32.5 小时" : "This Week · 32.5h")
            XCTAssertEqual(categoryStatsHeader(elapsed), chinese ? "本周 · 已过 62 小时" : "This Week · 62h elapsed")
            elapsed.categories[0].hours += 10
            elapsed.totalHours += 10
            XCTAssertEqual(categoryStatsHeader(elapsed), chinese ? "本周 · 已过 62 小时" : "This Week · 62h elapsed",
                           "the span, not what was logged in it")
            elapsed.status = .empty
            XCTAssertEqual(categoryStatsHeader(elapsed), chinese ? "本周" : "This Week")
        }
    }

    @MainActor
    func testComposedStrings() {
        UserDefaults.standard.set("en", forKey: AppSettingsLocale.languageKey)
        XCTAssertEqual(LFormat.statsHeader(.week, hours: 32.5), "This Week · 32.5h")
        XCTAssertEqual(LFormat.statsHours(13.62), "13.6h")
        XCTAssertEqual(LFormat.statsRemainder(3), "3 more")
        XCTAssertEqual(LFormat.statsMessage(.empty, period: .week), "Nothing logged this week")
        XCTAssertEqual(LFormat.statsMessage(.empty, period: .today), "Nothing logged today")
        XCTAssertEqual(LFormat.statsMessage(.noData, period: .month), "Open Done to start")
        XCTAssertEqual(LFormat.statsMessage(.stale, period: .month), "Open Done to refresh")
        XCTAssertNil(LFormat.statsMessage(.ok, period: .month))
        XCTAssertEqual(LFormat.statsElapsedHeader(.week, hours: 62.3), "This Week · 62h elapsed")
        XCTAssertEqual(LFormat.statsElapsedHeader(.today, hours: 13.7), "Today · 14h elapsed", "whole hours")
        XCTAssertEqual(LFormat.statsElapsedHeader(.month, hours: 504), "This Month · 504h elapsed")
        XCTAssertEqual(L(.statsUnlogged), "Unlogged")

        UserDefaults.standard.set("zh", forKey: AppSettingsLocale.languageKey)
        XCTAssertEqual(LFormat.statsHeader(.week, hours: 32.5), "本周 · 32.5 小时")
        XCTAssertEqual(LFormat.statsRemainder(3), "其余 3 类")
        XCTAssertEqual(LFormat.statsMessage(.empty, period: .week), "本周还没有记录")
        XCTAssertEqual(LFormat.statsMessage(.empty, period: .month), "本月还没有记录")
        XCTAssertEqual(LFormat.statsMessage(.noData, period: .week), "打开 Done 开始统计")
        XCTAssertEqual(LFormat.statsMessage(.stale, period: .week), "打开 Done 更新数据")
        XCTAssertEqual(LFormat.statsElapsedHeader(.week, hours: 62.3), "本周 · 已过 62 小时")
        XCTAssertEqual(LFormat.statsElapsedHeader(.today, hours: -1), "今天 · 已过 0 小时")
        XCTAssertEqual(L(.statsUnlogged), "未记录")
    }

    /// "Unlogged" is no category's name and no remainder label: the row it
    /// heads is the time nothing covered.
    @MainActor
    func testTheUnloggedLabelIsNeitherACategoryNorTheRemainder() {
        for language in ["en", "zh"] {
            UserDefaults.standard.set(language, forKey: AppSettingsLocale.languageKey)
            let label = L(.statsUnlogged)
            for word in ["Other", "Others", "其他", "其它"] { XCTAssertNotEqual(label, word) }
            for count in [2, 3] { XCTAssertNotEqual(label, LFormat.statsRemainder(count)) }
        }
    }

    /// The remainder row can never read as a category: not "Other" (the
    /// Analysis tab's bucket for untyped time, and a name a type can have),
    /// not its translation, and always with the count in it.
    @MainActor
    func testTheRemainderLabelIsNeverACategoryName() {
        for language in ["en", "zh"] {
            UserDefaults.standard.set(language, forKey: AppSettingsLocale.languageKey)
            for count in [2, 3, 11] {
                let label = LFormat.statsRemainder(count)
                for word in ["Other", "Others", "其他", "其它"] { XCTAssertNotEqual(label, word) }
                XCTAssertTrue(label.contains("\(count)"), label)
            }
        }
    }

    @MainActor
    func testHoursNumbers() {
        XCTAssertEqual(LFormat.statsHoursNumber(0), "0.0")
        XCTAssertEqual(LFormat.statsHoursNumber(99.94), "99.9")
        XCTAssertEqual(LFormat.statsHoursNumber(99.96), "100")
        XCTAssertEqual(LFormat.statsHoursNumber(245.34), "245")
        XCTAssertEqual(LFormat.statsHoursNumber(-3), "0.0")
        XCTAssertEqual(LFormat.statsHoursNumber(.nan), "0.0")
    }
}

// MARK: - The widget target, source-pinned

/// `DoneWidget` has no test bundle, so what only it compiles — the intent,
/// the provider, the family switch, the bundle — is pinned by source scan
/// (the `WidgetViewSourcePinTests` idiom; weaker than behaviour, declared as
/// such). The faces themselves are behaviourally tested above.
final class CategoryStatsWidgetSourcePinTests: XCTestCase {
    private func source(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(path)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Code without comment lines, whitespace collapsed: a pin is met by
    /// code, not by a comment quoting it.
    private func code(_ path: String) throws -> String {
        try source(path).split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("///") }
            .joined(separator: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    func testTheBundleRegistersTheWidget() throws {
        XCTAssertTrue(try code("DoneWidget/DoneWidgetBundle.swift").contains("CategoryStatsWidget()"))
    }

    func testTheProviderRunsOnTheSharedScheduleAndReadsEachEntryAtItsOwnInstant() throws {
        let src = try code("DoneWidget/CategoryStatsWidget.swift")
        for pin in ["WidgetTimelineSchedule.entryDates(events: SharedWidgetData.read(), now: .now, calendar: calendar)",
                    ".map { date in Self.entry(at: date, payload: payload, options: options) }",
                    "CategoryStats.summary(of: payload, options: options, asOf: date)",
                    "let options = configuration.options",
                    "Timeline(entries: entries, policy: .atEnd)",
                    "let calendar = payload?.resolvedCalendar() ?? .current",
                    "if context.isPreview {",
                    "CategoryStatsLayout.sample(options.period, basis: options.basis,",
                    "AppIntentConfiguration(kind: kind, intent: CategoryStatsConfigurationIntent.self,",
                    ".supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular])",
                    ".configurationDisplayName(L(.categoryStats))", ".description(LFormat.categoryStatsDescription())",
                    "let accented = renderingMode != .fullColor",
                    "let face = CategoryStatsFace(family: family)",
                    ".containerBackground(.background, for: .widget)"] {
            XCTAssertTrue(src.contains(pin), "missing: \(pin)")
        }
        XCTAssertFalse(src.contains("policy: .after"), "no periodic pull (gh#219)")
        XCTAssertEqual(src.components(separatedBy: "CategoryStatsWidgetView(summary: entry.summary, face: face, accented: accented)")
            .count - 1, 2, "every family draws the shared face its family maps to")
    }

    /// The Edit Widget sheet: the period (this week), the basis (share of
    /// logged time) and the exclusion (off), each with its default; the
    /// exclusion offered only in the logged basis; and the three read into
    /// the options the summary takes.
    func testTheOptionsTheirDefaultsAndWhenTheExclusionShows() throws {
        let src = try code("DoneWidget/CategoryStatsWidget.swift")
        for pin in ["@Parameter(title: \"Period\", default: .week) var period: CategoryStatsPeriodOption",
                    "@Parameter(title: \"Show as\", default: .logged) var basis: CategoryStatsBasisOption",
                    "@Parameter(title: \"Exclude background categories\", description: \"Leaves out the categories "
                        + "selected under Me › Edit profile › Hide from Me tab.\", default: false) var excludesBackground: Bool",
                    "When(\\CategoryStatsConfigurationIntent.$basis, .equalTo, CategoryStatsBasisOption.logged) { "
                        + "Summary { \\.$period \\.$basis \\.$excludesBackground } } otherwise: { "
                        + "Summary { \\.$period \\.$basis } }",
                    "CategoryStatsOptions(period: period.statsPeriod, basis: basis.statsBasis, "
                        + "excludesBackground: excludesBackground)",
                    "case .logged: return .logged", "case .elapsed: return .elapsed"] {
            XCTAssertTrue(src.contains(pin), "missing: \(pin)")
        }
    }

    /// The faces take their rows, shares and percents from
    /// `CategoryStats.breakdown` and draw them; no percent is computed in
    /// the view file.
    func testTheFacesUseTheSharedBreakdown() throws {
        let src = try code("Shared/CategoryStatsWidgetViews.swift")
        XCTAssertGreaterThanOrEqual(src.components(separatedBy: "CategoryStats.breakdown(").count - 1, 5)
        XCTAssertTrue(src.contains("Text(row.percentText)"))
        XCTAssertTrue(src.contains("Text(top?.percentText ?? \"--\")"))
        XCTAssertTrue(src.contains("let top = CategoryStatsLayout.ringLeader(summary)"), "the ring draws the tested leader")
        XCTAssertEqual(src.components(separatedBy: "Text(categoryStatsHeader(summary))").count - 1, 2,
                       "both list faces set the tested header")
        XCTAssertTrue(src.contains("LFormat.statsRemainder(count)"))
        XCTAssertTrue(src.contains("segments.map(\\.share)"))
        XCTAssertTrue(src.contains("Text(L(.statsUnlogged))"))
        XCTAssertGreaterThanOrEqual(src.components(separatedBy: "unlogged: unlogged").count - 1, 4,
                                    "every list and bar takes the elapsed basis's unlogged time")
        for arithmetic in ["* 100", "/ summary.totalHours", ".hours /", "percents("] {
            XCTAssertFalse(src.contains(arithmetic), "the view does its own arithmetic: \(arithmetic)")
        }
        XCTAssertGreaterThanOrEqual(src.components(separatedBy: ".widgetAccentable()").count - 1, 3)
    }

    /// Every sync test replaces the clock seam, so its production default is
    /// observed by nothing behavioural — the same gap the reload seam's pin
    /// (`WidgetTimelinePolicySourcePinTests`) closes for that seam.
    func testTheSyncClockSeamDefaultsToTheWallClock() throws {
        let src = try code("Done/Models/EventStore.swift")
        XCTAssertTrue(src.contains("var widgetSyncClock: () -> Date = { Date() }"))
        XCTAssertTrue(src.contains("let now = widgetSyncClock()"))
        XCTAssertTrue(src.contains("self.syncWidgetSnapshots(deferringStats: true)"),
                      "the debounced sync is the one that waits for the build to write")
        XCTAssertTrue(src.contains("var categoryStatsInlineWork = EventStore.categoryStatsInlineWorkDefault"),
                      "production runs on the default budget")
        XCTAssertTrue(src.contains(
            "var categoryStatsBuildProbe: (@Sendable (_ daysBuilt: Int, _ events: Int, _ onMainThread: Bool) -> Void)?"))
        XCTAssertFalse(src.contains("categoryStatsBuildProbe = {"), "nothing in the app sets the probe")
    }

    /// The intent's strings are App Intents metadata: each literal is a key
    /// of the widget target's String Catalog with a Simplified Chinese
    /// translation, and the project knows the region.
    func testTheIntentStringsAreInTheCatalogInBothLanguages() throws {
        let src = try code("DoneWidget/CategoryStatsWidget.swift")
        var literals: [String] = []
        for marker in ["DisplayRepresentation(title: \"", "TypeDisplayRepresentation(name: \"", "@Parameter(title: \"",
                       "description: \"", "IntentDescription(\"", "LocalizedStringResource = \""] {
            for piece in src.components(separatedBy: marker).dropFirst() {
                literals.append(String(piece.prefix { $0 != "\"" }))
            }
        }
        XCTAssertEqual(Set(literals), ["Today", "This Week", "This Month", "Period", "Choose the span the widget adds up.",
                                       "Time by Category", "Share Basis", "Share of logged time", "Share of elapsed time",
                                       "Show as", "Exclude background categories",
                                       "Leaves out the categories selected under Me › Edit profile › Hide from Me tab."])
        let catalog = try JSONSerialization.jsonObject(with: Data(source("DoneWidget/Localizable.xcstrings").utf8))
        let strings = try XCTUnwrap((catalog as? [String: Any])?["strings"] as? [String: Any])
        for literal in Set(literals) {
            let entry = try XCTUnwrap(strings[literal] as? [String: Any], "\(literal) is not in the catalog")
            let zh = (((entry["localizations"] as? [String: Any])?["zh-Hans"] as? [String: Any])?["stringUnit"]
                      as? [String: Any])
            XCTAssertEqual(zh?["state"] as? String, "translated", literal)
            let value = try XCTUnwrap(zh?["value"] as? String, literal)
            XCTAssertFalse(value.isEmpty)
            XCTAssertNotEqual(value, literal, "\(literal) is untranslated")
        }
        let project = try source("Done.xcodeproj/project.pbxproj")
        XCTAssertTrue(project.contains("\"zh-Hans\","), "knownRegions has Simplified Chinese")
        XCTAssertTrue(project.contains("/* Localizable.xcstrings in Resources */"), "the catalog is a widget resource")
    }
}
