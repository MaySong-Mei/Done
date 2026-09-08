import XCTest
@testable import Done

/// gh#219 (render read/allocation hot-path cleanup) — behavior-preservation
/// pins for the formatter conversions in slices A and B.
///
/// Each converted formatter used to be built fresh on EVERY read (a
/// `DateFormatter` + often a `Locale` + a `UserDefaults` read, and for the
/// legend's `monthDayWeekday` an ICU `setLocalizedDateFormatFromTemplate`
/// run) in code that fires per scroll frame / per 1Hz tick / per visible
/// block. The conversion builds one instance per (language | 12h/24h)
/// combination up front and SELECTS between them, mirroring the accepted
/// `EventBlock.swift` `timeFormatter24`/`timeFormatter12` pattern.
///
/// These tests re-derive the OLD per-read construction inline and assert the
/// NEW selected instance produces a byte-identical string, across every axis
/// the formatter actually varies on. A pair that selects the wrong arm, or a
/// converted formatter whose config drifted from the original, fails here.
final class RenderReadFormatterEquivalenceTests: XCTestCase {

    // MARK: - Setting harness (UserDefaults.standard, save/restore)

    private func withLanguage(_ lang: String, _ body: () -> Void) {
        let key = AppSettingsLocale.languageKey
        let previous = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(lang, forKey: key)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        body()
    }

    private func withTimeFormat(_ raw: String, _ body: () -> Void) {
        let key = AppSettingsLocale.timeFormatKey
        let previous = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(raw, forKey: key)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        body()
    }

    /// A fixed instant. The equivalence being proved is selected == fresh for
    /// the SAME Date with IDENTICAL formatter config, so the host time zone is
    /// irrelevant (both sides read it the same way); only a stable Date matters.
    private func fixedDate(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 13, _ mi: Int = 37) -> Date {
        var c = DateComponents()
        c.year = y; c.month = mo; c.day = d; c.hour = h; c.minute = mi
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: c)!
    }

    private func freshFixed(_ localeID: String, _ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: localeID)
        f.dateFormat = format
        return f
    }

    private func freshTemplated(_ localeID: String, _ template: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: localeID)
        f.setLocalizedDateFormatFromTemplate(template)
        return f
    }

    // MARK: - Slice A: CalendarLegendFormatters (varies on language only)

    private let langLocalePairs: [(lang: String, localeID: String)] =
        [("en", "en_US"), ("zh", "zh_CN")]

    func testLegendFormattersMatchFreshConstructionBothLanguages() {
        let date = fixedDate(2026, 3, 15)          // Sunday, mid-March
        for (lang, localeID) in langLocalePairs {
            withLanguage(lang) {
                XCTAssertEqual(
                    CalendarLegendFormatters.yearOnly.string(from: date),
                    freshFixed(localeID, "yyyy").string(from: date), "yearOnly lang=\(lang)")
                XCTAssertEqual(
                    CalendarLegendFormatters.fullMonth.string(from: date),
                    freshFixed(localeID, "LLLL").string(from: date), "fullMonth lang=\(lang)")
                XCTAssertEqual(
                    CalendarLegendFormatters.shortMonth.string(from: date),
                    freshFixed(localeID, "MMM").string(from: date), "shortMonth lang=\(lang)")
                XCTAssertEqual(
                    CalendarLegendFormatters.shortWeekday.string(from: date),
                    freshFixed(localeID, "EEE").string(from: date), "shortWeekday lang=\(lang)")
                XCTAssertEqual(
                    CalendarLegendFormatters.monthDayWeekday.string(from: date),
                    freshTemplated(localeID, "MMMdEEEE").string(from: date), "monthDayWeekday lang=\(lang)")
            }
        }
    }

    /// Discriminating power for the wrong-arm mutation: en and zh must produce
    /// DIFFERENT strings for these formatters, so a selector that always
    /// returns the en (or zh) arm is caught by the equivalence test above.
    func testLegendFormattersActuallyDifferByLanguage() {
        let date = fixedDate(2026, 3, 15)
        var en: [String] = []
        var zh: [String] = []
        withLanguage("en") {
            en = [CalendarLegendFormatters.fullMonth.string(from: date),
                  CalendarLegendFormatters.shortMonth.string(from: date),
                  CalendarLegendFormatters.shortWeekday.string(from: date),
                  CalendarLegendFormatters.monthDayWeekday.string(from: date)]
        }
        withLanguage("zh") {
            zh = [CalendarLegendFormatters.fullMonth.string(from: date),
                  CalendarLegendFormatters.shortMonth.string(from: date),
                  CalendarLegendFormatters.shortWeekday.string(from: date),
                  CalendarLegendFormatters.monthDayWeekday.string(from: date)]
        }
        for i in en.indices {
            XCTAssertNotEqual(en[i], zh[i], "formatter #\(i) must differ en vs zh")
        }
    }

    /// The old `appLocale` mapped ANY non-"zh" language to en_US. An unset /
    /// unknown language must still select the English arm.
    func testLegendUnknownLanguageSelectsEnglishArm() {
        let date = fixedDate(2026, 3, 15)
        withLanguage("fr") {
            XCTAssertEqual(
                CalendarLegendFormatters.monthDayWeekday.string(from: date),
                freshTemplated("en_US", "MMMdEEEE").string(from: date))
        }
    }

    // MARK: - Slice B: time-of-day formatters (vary on 12h/24h only)

    /// Times that exercise am, pm, midnight and noon boundaries.
    private let sampleTimes: [(Int, Int)] = [(9, 5), (13, 37), (0, 0), (12, 0), (23, 59)]

    /// Reconstructs the OLD per-read `h:mm a` (variant P) 12h formatter.
    private func freshP12() -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "h:mm a"
        f.amSymbol = "am"; f.pmSymbol = "pm"
        return f
    }
    /// Reconstructs the OLD per-read `h:mma` (variant Q/R) 12h formatter.
    private func freshQ12() -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "h:mma"
        f.amSymbol = "am"; f.pmSymbol = "pm"
        return f
    }
    private func fresh24() -> DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "H:mm"
        return f
    }

    /// Runs `body` under every (language, time-format) combination, passing an
    /// `is24` flag and the fresh reference formatter for the active format.
    private func forEachFormatAndLanguage(twelve: @escaping () -> DateFormatter,
                                          _ body: (_ is24: Bool, _ fresh: DateFormatter) -> Void) {
        for lang in ["en", "zh"] {
            withLanguage(lang) {
                withTimeFormat("24h") { body(true, fresh24()) }
                withTimeFormat("12h") { body(false, twelve()) }
            }
        }
    }

    func testInterruptComposerFormatterMatchesFreshConstruction() {
        forEachFormatAndLanguage(twelve: { self.freshP12() }) { _, fresh in
            for (h, mi) in sampleTimes {
                let t = fixedDate(2026, 3, 15, h, mi)
                XCTAssertEqual(CalendarInterruptComposer.timeFormatter.string(from: t),
                               fresh.string(from: t), "\(h):\(mi)")
            }
        }
    }

    func testCalendarDayLayerFormatterMatchesFreshConstruction() {
        forEachFormatAndLanguage(twelve: { self.freshP12() }) { _, fresh in
            for (h, mi) in sampleTimes {
                let t = fixedDate(2026, 3, 15, h, mi)
                XCTAssertEqual(DayLayerHostView.timeFormatter().string(from: t),
                               fresh.string(from: t), "\(h):\(mi)")
            }
        }
    }

    func testTimelineCurrentTimeFormatterMatchesFreshConstruction() {
        // The formatter is `h:mma`; the `.lowercased()` lives at the call site,
        // so the formatter itself equals the non-lowercased Q/R reconstruction.
        forEachFormatAndLanguage(twelve: { self.freshQ12() }) { _, fresh in
            for (h, mi) in sampleTimes {
                let t = fixedDate(2026, 3, 15, h, mi)
                XCTAssertEqual(TimeAxisLabels.currentTimeFormatter.string(from: t),
                               fresh.string(from: t), "\(h):\(mi)")
            }
        }
    }

    func testFocusEventFlowFormatterMatchesFreshConstruction() {
        forEachFormatAndLanguage(twelve: { self.freshQ12() }) { _, fresh in
            for (h, mi) in sampleTimes {
                let t = fixedDate(2026, 3, 15, h, mi)
                XCTAssertEqual(FocusEventFlowView.currentTimeFormatter.string(from: t),
                               fresh.string(from: t), "\(h):\(mi)")
            }
        }
    }

    func testTimeAxisLayerCurrentTimeTextMatchesFreshConstruction() {
        // Returns the fully-formatted string INCLUDING the `.lowercased()`
        // that mirrors the SwiftUI tree, so the reference lowercases too.
        forEachFormatAndLanguage(twelve: { self.freshQ12() }) { _, fresh in
            for (h, mi) in sampleTimes {
                let t = fixedDate(2026, 3, 15, h, mi)
                XCTAssertEqual(TimeAxisLayerView.currentTimeText(for: t),
                               fresh.string(from: t).lowercased(), "\(h):\(mi)")
            }
        }
    }

    /// Discriminating power for the wrong-arm mutation: for every converted
    /// time formatter, the 24h and 12h renderings of an afternoon time must
    /// differ, so a selector stuck on one arm is caught above.
    func testTimeFormattersDiscriminateBetweenArms() {
        let t = fixedDate(2026, 3, 15, 13, 37)
        func pair(_ read: () -> String) -> (String, String) {
            var a = "", b = ""
            withTimeFormat("24h") { a = read() }
            withTimeFormat("12h") { b = read() }
            return (a, b)
        }
        withLanguage("en") {
            let ic = pair { CalendarInterruptComposer.timeFormatter.string(from: t) }
            XCTAssertNotEqual(ic.0, ic.1, "InterruptComposer")
            let dl = pair { DayLayerHostView.timeFormatter().string(from: t) }
            XCTAssertNotEqual(dl.0, dl.1, "DayLayer")
            let tl = pair { TimeAxisLabels.currentTimeFormatter.string(from: t) }
            XCTAssertNotEqual(tl.0, tl.1, "Timeline")
            let fe = pair { FocusEventFlowView.currentTimeFormatter.string(from: t) }
            XCTAssertNotEqual(fe.0, fe.1, "FocusFlow")
            let ax = pair { TimeAxisLayerView.currentTimeText(for: t) }
            XCTAssertNotEqual(ax.0, ax.1, "TimeAxis")
        }
    }

}
