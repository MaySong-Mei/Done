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
    /// family's widths over the same heights, and lock-screen sizes from
    /// below the smallest device up.
    static let boxes: [CategoryStatsFace: [CGSize]] = [
        .small: [CGSize(width: 116, height: 116), CGSize(width: 126, height: 126), CGSize(width: 138, height: 138)],
        .medium: [CGSize(width: 289, height: 116), CGSize(width: 306, height: 126), CGSize(width: 332, height: 138)],
        .rectangular: [CGSize(width: 153, height: 64), CGSize(width: 157, height: 67), CGSize(width: 160, height: 72),
                       CGSize(width: 172, height: 76)],
        .circular: [CGSize(width: 64, height: 64), CGSize(width: 68, height: 68), CGSize(width: 72, height: 72),
                    CGSize(width: 76, height: 76)],
    ]

    private static func summary(_ names: [String], hours: [Double], period: CategoryStatsPeriod = .week) -> CategoryStatsSummary {
        let categories = zip(names, hours).map { CategoryHours(name: $0, colorHex: nil, hours: $1) }
        return CategoryStatsSummary(period: period, status: .ok, categories: CategoryStats.ranked(
            Dictionary(categories.map { ($0.name, $0.hours) }, uniquingKeysWith: +)
        ), totalHours: hours.reduce(0, +))
    }

    /// Long names, more categories than any face lists, a literal "Other",
    /// a sliver under 1%, and a month's worth of hours in the header.
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
        XCTAssertEqual(renders, 2 * 6 * 14 * 7)
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

    /// Rows a face drew, counted from the right edge, where every row ends
    /// in its percent and nothing else reaches but the bar: the inked runs
    /// down a 4pt band at the right edge — runs under 4pt apart being one
    /// glyph, a "%" (rows are 10pt apart) — less the bar's.
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
        let band = (w - Int(4 * scale))..<w
        let inked = (0..<h).map { y in band.contains { x in pixels[(y * w + x) * 4 + 3] > 24 } }
        var runs = 0
        var lastInk = -Int.max / 2
        for y in 0..<h where inked[y] {
            if y - lastInk > Int(4 * scale) { runs += 1 }
            lastInk = y
        }
        return runs - 1
    }

    /// How many rows each face keeps, by box, language and Bold Text, for
    /// the seven-category month (printed for the record): every face keeps
    /// its whole cap — the small face two leaders and the remainder, the
    /// medium four and the remainder, the lock screen two leaders — in every
    /// box. Were a face ever to give a row up, the render test above is
    /// what says it did so inside the box.
    func testRowsKeptByFaceAndBox() throws {
        var table: [String] = []
        for language in ["en", "zh"] {
            setLanguage(language)
            let summary = Self.contents(chinese: language == "zh")[0].1
            for face in [CategoryStatsFace.small, .medium, .rectangular] {
                for box in Self.boxes[face]! {
                    for bold in [false, true] {
                        let rows = try rowsDrawn(CategoryStatsWidgetView(summary: summary, face: face, accented: false),
                                                 box: box, bold: bold)
                        table.append("\(face) \(Int(box.width))x\(Int(box.height)) \(language) bold=\(bold): \(rows)")
                        XCTAssertEqual(rows, CategoryStatsLayout.rowCap(face),
                                       "\(face) \(box) \(language) bold \(bold): \(rows) rows")
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

    @MainActor
    func testTheAccentedLadderFallsWithRankAndStaysVisible() {
        let ladder = (0..<6).map { CategoryStatsLayout.accentedOpacity(rank: $0) }
        for (a, b) in zip(ladder, ladder.dropFirst().prefix(4)) { XCTAssertGreaterThan(a, b) }
        XCTAssertEqual(ladder[0], 1)
        XCTAssertGreaterThan(ladder.last!, CategoryStatsLayout.remainderAccentedOpacity,
                             "the remainder is fainter than any ranked category")
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
        XCTAssertEqual(CategoryStatsFace.allCases.map(CategoryStatsLayout.rowCap), [3, 5, 2, 1])
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
        .categoryStats, .categoryStatsDesc, .statsPeriodToday, .statsPeriodWeek, .statsPeriodMonth,
        .statsHeaderFormat, .statsHoursFormat, .statsRemainderFormat, .statsOpenToStart, .statsOpenToRefresh,
        .statsEmptyToday, .statsEmptyWeek, .statsEmptyMonth,
    ]

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

    func testTheGalleryNameAndDescription() {
        XCTAssertEqual(LKey.categoryStats.text(for: .english), "Time by Category")
        XCTAssertEqual(LKey.categoryStats.text(for: .chinese), "类别占比")
        XCTAssertEqual(LKey.categoryStatsDesc.text(for: .english), "How your recent time splits across categories.")
        XCTAssertEqual(LKey.categoryStatsDesc.text(for: .chinese), "最近一段时间里各类事件的时间占比。")
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

        UserDefaults.standard.set("zh", forKey: AppSettingsLocale.languageKey)
        XCTAssertEqual(LFormat.statsHeader(.week, hours: 32.5), "本周 · 32.5 小时")
        XCTAssertEqual(LFormat.statsRemainder(3), "其余 3 类")
        XCTAssertEqual(LFormat.statsMessage(.empty, period: .week), "本周还没有记录")
        XCTAssertEqual(LFormat.statsMessage(.empty, period: .month), "本月还没有记录")
        XCTAssertEqual(LFormat.statsMessage(.noData, period: .week), "打开 Done 开始统计")
        XCTAssertEqual(LFormat.statsMessage(.stale, period: .week), "打开 Done 更新数据")
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
                    ".map { date in Self.entry(at: date, payload: payload, period: period) }",
                    "CategoryStats.summary(of: payload, period: period, asOf: date)",
                    "Timeline(entries: entries, policy: .atEnd)",
                    "let calendar = payload?.resolvedCalendar() ?? .current",
                    "if context.isPreview {",
                    "AppIntentConfiguration(kind: kind, intent: CategoryStatsConfigurationIntent.self,",
                    ".supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular])",
                    ".configurationDisplayName(L(.categoryStats))", ".description(L(.categoryStatsDesc))",
                    "@Parameter(title: \"Period\", default: .week)",
                    "let accented = renderingMode != .fullColor",
                    ".containerBackground(.background, for: .widget)"] {
            XCTAssertTrue(src.contains(pin), "missing: \(pin)")
        }
        XCTAssertFalse(src.contains("policy: .after"), "no periodic pull (gh#219)")
        XCTAssertEqual(src.components(separatedBy: "CategoryStatsWidgetView(summary: entry.summary, face: ").count - 1, 4,
                       "every family draws a shared face")
    }

    /// The faces take their rows, shares and percents from
    /// `CategoryStats.breakdown` and draw them; no percent is computed in
    /// the view file.
    func testTheFacesUseTheSharedBreakdown() throws {
        let src = try code("Shared/CategoryStatsWidgetViews.swift")
        XCTAssertGreaterThanOrEqual(src.components(separatedBy: "CategoryStats.breakdown(").count - 1, 5)
        XCTAssertTrue(src.contains("Text(row.percentText)"))
        XCTAssertTrue(src.contains("Text(top?.percentText ?? \"--\")"))
        XCTAssertTrue(src.contains("LFormat.statsRemainder(count)"))
        XCTAssertTrue(src.contains("rows.map(\\.share)"))
        for arithmetic in ["* 100", "/ summary.totalHours", ".hours /", "percents("] {
            XCTAssertFalse(src.contains(arithmetic), "the view does its own arithmetic: \(arithmetic)")
        }
        XCTAssertGreaterThanOrEqual(src.components(separatedBy: ".widgetAccentable()").count - 1, 3)
    }

    /// The intent's strings are App Intents metadata: each literal is a key
    /// of the widget target's String Catalog with a Simplified Chinese
    /// translation, and the project knows the region.
    func testTheIntentStringsAreInTheCatalogInBothLanguages() throws {
        let src = try code("DoneWidget/CategoryStatsWidget.swift")
        var literals: [String] = []
        for marker in ["DisplayRepresentation(title: \"", "TypeDisplayRepresentation(name: \"", "@Parameter(title: \"",
                       "IntentDescription(\"", "LocalizedStringResource = \""] {
            for piece in src.components(separatedBy: marker).dropFirst() {
                literals.append(String(piece.prefix { $0 != "\"" }))
            }
        }
        XCTAssertEqual(Set(literals), ["Today", "This Week", "This Month", "Period", "Choose the span the widget adds up.",
                                       "Time by Category"])
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
