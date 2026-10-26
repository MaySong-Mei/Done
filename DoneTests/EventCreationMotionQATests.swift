//
//  EventCreationMotionQATests.swift
//  DoneTests
//
//  Independent QA for the create-motion spike. Every "is not held" / "is
//  dropped" assertion runs beside a positive control on the SAME rig that
//  proves the rig can observe a hold (or a played motion).
//
//  Observables (the host's reveal list is private):
//    * chrome = the host's sublayers after an empty apply (identity set);
//      every other sublayer is a block container (plain CALayer, no
//      contents) or a motion piece (has contents, or is a shape layer);
//    * a held block is a hidden block container;
//    * a full variant adds pieces carrying the "createMotion" animation; the
//      lightweight fade adds none and puts "createMotion" on the container;
//    * the 12-reveal cap: a host whose reveal list was NOT drained after an
//      exit holds fewer than 12 fresh arrivals.
//
//  Open findings, if any, live in `EventCreationMotionQAFindings` and are
//  expected RED.
//

import XCTest
import UIKit
@testable import Done

@MainActor
class EventCreationMotionQABase: XCTestCase {
    var savedCreateEnabled: (() -> Bool)!
    var savedDeleteEnabled: (() -> Bool)!
    var savedCreateVariant: Any?
    var savedDeleteVariant: Any?
    var suiteName: String!
    var defaults: UserDefaults!
    var location: EventStorageLocation!
    var window: UIWindow?

    let createVariantKey = SpikeFeatureFlag.variantKey(EventCreationMotionFlag.spikeID)
    let createEnabledKey = SpikeFeatureFlag.enabledKey(EventCreationMotionFlag.spikeID)
    let deleteVariantKey = SpikeFeatureFlag.variantKey(EventDeletionMotionFlag.spikeID)

    override func setUp() {
        super.setUp()
        savedCreateEnabled = EventCreationMotionRegistry.shared.isEnabled
        savedDeleteEnabled = EventDeletionMotionRegistry.shared.isEnabled
        EventCreationMotionRegistry.shared.isEnabled = { true }
        EventDeletionMotionRegistry.shared.isEnabled = { false }
        savedCreateVariant = UserDefaults.standard.object(forKey: createVariantKey)
        savedDeleteVariant = UserDefaults.standard.object(forKey: deleteVariantKey)
        setVariant(.assemble)
        UserDefaults.standard.set(EventDeletionMotionVariant.dissolve.rawValue, forKey: deleteVariantKey)
        suiteName = "EventCreationMotionQATests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        location = TestStorage.reset(suiteName)
    }

    override func tearDown() {
        EventCreationMotionRegistry.shared.isEnabled = savedCreateEnabled
        EventDeletionMotionRegistry.shared.isEnabled = savedDeleteEnabled
        restore(savedCreateVariant, createVariantKey)
        restore(savedDeleteVariant, deleteVariantKey)
        if let root = window?.rootViewController, root.presentedViewController != nil {
            root.dismiss(animated: false)
        }
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
        TestStorage.tearDown(suiteName)
        defaults = nil
        location = nil
        super.tearDown()
    }

    func restore(_ value: Any?, _ key: String) {
        if let value { UserDefaults.standard.set(value, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
    }

    func setVariant(_ variant: EventCreationMotionVariant) {
        UserDefaults.standard.set(variant.rawValue, forKey: createVariantKey)
    }

    // MARK: Fixtures

    var calendar: Calendar { .current }
    var today: Date { calendar.startOfDay(for: Date()) }
    func day(_ n: Int) -> Date { calendar.date(byAdding: .day, value: n, to: today)! }

    func makeStore(seeds: Bool = false) -> EventStore {
        EventStore(defaults: defaults, storage: location, seedsSampleDataIfEmpty: seeds)
    }

    func plainEvent(_ title: String, on date: Date? = nil, hour: Double = 9) -> Event {
        let start = (date ?? today).addingTimeInterval(hour * 3600)
        return Event(title: title, timeRanges: [.init(start: start, end: start.addingTimeInterval(3600))], type: "Study")
    }

    func dailySeries(_ title: String, hour: Double = 9, duration: TimeInterval = 3600, from start: Date? = nil) -> Event {
        let s = (start ?? today).addingTimeInterval(hour * 3600)
        var series = Event(title: title, timeRanges: [.init(start: s, end: s.addingTimeInterval(duration))], type: "Study")
        series.repeatUnit = .day
        series.repeatInterval = 1
        return series
    }

    func occurrence(id: String, date: Date? = nil, hour: Double) -> CalendarLayout.EventOccurrence {
        let start = (date ?? today).addingTimeInterval(hour * 3600)
        let range = Event.TimeRange(start: start, end: start.addingTimeInterval(3600))
        return CalendarLayout.EventOccurrence(
            id: id, event: Event(title: id, timeRanges: [range], type: "Study"), range: range
        )
    }

    func occs(_ prefix: String, hours: [Double]) -> [CalendarLayout.EventOccurrence] {
        hours.map { occurrence(id: "\(prefix)\(Int($0))-\(UUID().uuidString)", hour: $0) }
    }

    func model(_ occurrences: [CalendarLayout.EventOccurrence], date: Date? = nil) -> DayLayerHostView.Model {
        DayLayerHostView.Model(
            date: date ?? today,
            occurrences: occurrences,
            contentWidth: 360,
            headerHeight: 16,
            hourHeight: 56,
            eventHorizontalInset: 8,
            leadingExtendedHours: 0,
            trailingExtendedHours: 0,
            drawableLeadingHours: 0,
            drawableTrailingHours: 0,
            useImperativeDayLayerModel: false,
            showEventText: true,
            isWeekMode: false,
            isThreeDayMode: false,
            titleFontSizeSetting: 13,
            showTimeBelowTitle: true,
            multiTypeEnabled: false,
            nearFutureHorizonDays: 7,
            isPinchActive: false,
            frozenSlotMinutes: nil
        )
    }

    func storeOccurrences(_ store: EventStore, on date: Date) -> [CalendarLayout.EventOccurrence] {
        CalendarLayout.occurrencesForDate(store.rawCalendarEvents, date: date)
    }

    func mark(
        _ occurrences: [CalendarLayout.EventOccurrence],
        source: EventCreationMotionRegistry.Source = .local,
        now: Date = Date()
    ) {
        EventCreationMotionRegistry.shared.mark(occurrences.map(\.event.id), source: source, now: now)
    }

    // MARK: Rig

    /// A host whose chrome (the sublayers present after an empty apply) is
    /// remembered by identity, so blocks and pieces can be told apart.
    final class Rig {
        let host: DayLayerHostView
        let chrome: Set<ObjectIdentifier>
        init(host: DayLayerHostView, chrome: Set<ObjectIdentifier>) {
            self.host = host
            self.chrome = chrome
        }
        var nonChrome: [CALayer] {
            (host.layer.sublayers ?? []).filter { !chrome.contains(ObjectIdentifier($0)) }
        }
        static func isPiece(_ l: CALayer) -> Bool { l.contents != nil || l is CAShapeLayer }
        var blocks: [CALayer] { nonChrome.filter { !Rig.isPiece($0) } }
        var hiddenBlocks: [CALayer] { blocks.filter(\.isHidden) }
        var createPieces: [CALayer] {
            nonChrome.filter { Rig.isPiece($0) && $0.animation(forKey: "createMotion") != nil }
        }
        var deletePieces: [CALayer] {
            nonChrome.filter { Rig.isPiece($0) && $0.animation(forKey: "deleteMotion") != nil }
        }
        /// Every non-chrome piece, animated or not (a leak would linger here).
        var allPieces: [CALayer] { nonChrome.filter(Rig.isPiece) }
        var fadingBlocks: [CALayer] { blocks.filter { $0.animation(forKey: "createMotion") != nil } }
    }

    func makeRig(_ occurrences: [CalendarLayout.EventOccurrence], date: Date? = nil,
                 frame: CGRect = CGRect(x: 0, y: 0, width: 360, height: 2000)) -> Rig {
        let host = DayLayerHostView(frame: frame)
        host.apply(model([], date: date))
        host.layoutIfNeeded()
        let chrome = Set((host.layer.sublayers ?? []).map(ObjectIdentifier.init))
        let rig = Rig(host: host, chrome: chrome)
        apply(rig, occurrences, date: date)
        return rig
    }

    func apply(_ rig: Rig, _ occurrences: [CalendarLayout.EventOccurrence], date: Date? = nil) {
        rig.host.apply(model(occurrences, date: date))
        rig.host.layoutIfNeeded()
    }

    func attachToWindow(_ host: UIView) {
        if window == nil {
            let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
            let w = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
            w.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
            w.isHidden = false
            window = w
        }
        window!.addSubview(host)
        host.layoutIfNeeded()
    }

    func pump(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }

    @discardableResult
    func pumpUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
        return condition()
    }

    struct Sample {
        let t: CFTimeInterval
        let pieces: Int
        let hidden: Int
        let fading: Set<ObjectIdentifier>
        let hiddenIDs: Set<ObjectIdentifier>
    }

    /// Samples the rig every run-loop turn for `seconds`; `t` is relative to
    /// `origin` (default: the call).
    func record(_ rig: Rig, _ seconds: TimeInterval, origin: CFTimeInterval? = nil) -> [Sample] {
        let start = origin ?? CACurrentMediaTime()
        let end = Date().addingTimeInterval(seconds)
        var out: [Sample] = []
        func take() {
            out.append(Sample(
                t: CACurrentMediaTime() - start,
                pieces: rig.createPieces.count,
                hidden: rig.hiddenBlocks.count,
                fading: Set(rig.fadingBlocks.map(ObjectIdentifier.init)),
                hiddenIDs: Set(rig.hiddenBlocks.map(ObjectIdentifier.init))
            ))
        }
        take()
        while Date() < end {
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
            take()
        }
        return out
    }

    func peak(_ s: [Sample]) -> Int { s.map(\.pieces).max() ?? 0 }
    func firstPieceTime(_ s: [Sample]) -> CFTimeInterval? { s.first { $0.pieces > 0 }?.t }

    /// Every exit must end here: no hidden block, no piece left anywhere.
    func assertClean(_ rig: Rig, blocks: Int, _ message: String = "",
                     file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(rig.hiddenBlocks.count, 0, "no hidden block left behind \(message)", file: file, line: line)
        XCTAssertEqual(rig.allPieces.count, 0, "no piece leaked \(message)", file: file, line: line)
        XCTAssertEqual(rig.blocks.count, blocks, "block count \(message)", file: file, line: line)
    }

    /// Off window, 12 fresh arrivals all wait hidden: if an earlier reveal
    /// was not removed from the host's list, the cap of 12 rejects one.
    func assertTwelveFreshHoldsFit(_ rig: Rig, keep: [CalendarLayout.EventOccurrence],
                                   file: StaticString = #filePath, line: UInt = #line) {
        rig.host.removeFromSuperview()
        apply(rig, keep)
        let twelve = (0..<12).map { occurrence(id: "F\($0)-\(UUID().uuidString)", hour: 6 + Double($0)) }
        mark(twelve)
        apply(rig, keep + twelve)
        XCTAssertEqual(rig.hiddenBlocks.count, 12, "12 fresh holds fit — earlier reveals released their slots",
                       file: file, line: line)
        apply(rig, keep)
        XCTAssertEqual(rig.hiddenBlocks.count, 0, file: file, line: line)
    }

    /// Max alpha byte of a CGImage held in a layer's `contents`.
    func maxAlpha(_ contents: Any?) -> UInt8? {
        guard let contents, CFGetTypeID(contents as CFTypeRef) == CGImage.typeID else { return nil }
        let image = contents as! CGImage
        let w = image.width, h = image.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let ok: Bool = data.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(
                data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        var m: UInt8 = 0
        for i in stride(from: 3, to: data.count, by: 4) where data[i] > m { m = data[i] }
        return m
    }
}

@MainActor
final class EventCreationMotionQATests: EventCreationMotionQABase {

    // MARK: Claim 1 — flag off is king's shape

    /// The registry's DEFAULT gate reads the spike's enabled key (the
    /// implementer's tests inject the closure, so they never exercise it).
    func testTheDefaultGateFollowsTheSpikeEnabledKey() {
        let saved = UserDefaults.standard.object(forKey: createEnabledKey)
        defer { restore(saved, createEnabledKey) }
        let registry = EventCreationMotionRegistry()
        let off = UUID(), on = UUID()
        UserDefaults.standard.set(false, forKey: createEnabledKey)
        registry.mark([off], source: .local)
        XCTAssertNil(registry.mark(for: off), "flag off must mark nothing")
        UserDefaults.standard.set(true, forKey: createEnabledKey)
        registry.mark([on], source: .local)
        XCTAssertNotNil(registry.mark(for: on), "control: key on marks")
    }

    /// End to end through the store and a host: flag off ⇒ an opted-in
    /// create and a remote arrival mark nothing and no block is hidden;
    /// flag on (control) ⇒ the same sequence holds both.
    func testFlagOffNothingIsMarkedAndNoBlockIsHidden() {
        func run(enabled: Bool) -> (hidden: Int, localMarked: Bool, remoteMarked: Bool) {
            EventCreationMotionRegistry.shared.isEnabled = { enabled }
            TestStorage.tearDown(suiteName)
            location = TestStorage.reset(suiteName)
            let store = makeStore()
            let keep = plainEvent("Keep", hour: 8)
            store.addCalendarEvent(keep)
            let rig = makeRig(storeOccurrences(store, on: today))
            let local = plainEvent("Local", hour: 11)
            let remote = plainEvent("Remote", hour: 14)
            store.addCalendarEvent(local, creationMotion: .local)
            store.applyRemoteCalendarRows(adopts: [remote], deletions: [])
            apply(rig, storeOccurrences(store, on: today))
            XCTAssertEqual(rig.blocks.count, 3, "fixture: three blocks rendered")
            let r = EventCreationMotionRegistry.shared
            return (rig.hiddenBlocks.count, r.mark(for: local.id) != nil, r.mark(for: remote.id) != nil)
        }
        let off = run(enabled: false)
        XCTAssertEqual(off.hidden, 0, "flag off: nothing is held")
        XCTAssertFalse(off.localMarked)
        XCTAssertFalse(off.remoteMarked)
        let on = run(enabled: true)
        XCTAssertEqual(on.hidden, 2, "control: flag on, both arrivals are held")
        XCTAssertTrue(on.localMarked)
        XCTAssertTrue(on.remoteMarked)
    }

    // MARK: Claim 2 — who is held

    func testAFirstRenderOfAFreshHostIsNotHeld() {
        let b = occurrence(id: "B-\(UUID().uuidString)", hour: 13)
        mark([b])
        let fresh = DayLayerHostView(frame: CGRect(x: 0, y: 0, width: 360, height: 2000))
        fresh.apply(model([b]))
        fresh.layoutIfNeeded()
        // The fresh host's chrome is unknown, so compare with a twin host fed
        // the same block unmarked.
        let twin = DayLayerHostView(frame: CGRect(x: 0, y: 0, width: 360, height: 2000))
        twin.apply(model([occurrence(id: "C-\(UUID().uuidString)", hour: 13)]))
        twin.layoutIfNeeded()
        let hidden = { (h: DayLayerHostView) in h.layer.sublayers?.filter(\.isHidden).count ?? 0 }
        XCTAssertEqual(hidden(fresh), hidden(twin), "a first render shows a marked block plainly")
        // Control: the same marked block arriving on a second pass is held.
        let rig = makeRig([])
        let c = occurrence(id: "C2-\(UUID().uuidString)", hour: 13)
        mark([c])
        apply(rig, [c])
        XCTAssertEqual(rig.hiddenBlocks.count, 1, "control: a second-pass arrival is held")
    }

    func testAColumnThatSwitchedDaysDoesNotHold() {
        func run(fromDay: Date) -> Int {
            let rig = makeRig([], date: fromDay)
            let b = occurrence(id: "B-\(UUID().uuidString)", hour: 13)
            mark([b])
            apply(rig, [b])
            XCTAssertEqual(rig.blocks.count, 1, "fixture")
            return rig.hiddenBlocks.count
        }
        XCTAssertEqual(run(fromDay: today), 1, "control: same day ⇒ held")
        XCTAssertEqual(run(fromDay: day(-1)), 0, "column came from yesterday ⇒ not held")
        XCTAssertEqual(run(fromDay: day(7)), 0, "column came from next week ⇒ not held")
    }

    /// Through the real store: a just-created (marked) event that is edited
    /// to a new time on the same day gets a new occurrence id — not a birth.
    func testAStoreEditThatReIdsAMarkedEventIsNotHeld() {
        let store = makeStore()
        let keep = plainEvent("Keep", hour: 7)
        store.addCalendarEvent(keep)
        let rig = makeRig(storeOccurrences(store, on: today))
        var made = plainEvent("Made", hour: 10)
        store.addCalendarEvent(made, creationMotion: .local)
        apply(rig, storeOccurrences(store, on: today))
        XCTAssertEqual(rig.hiddenBlocks.count, 1, "control: the create itself is held")
        // A second column that has already got the block (held as well —
        // the edit then lands on a day that showed it).
        let rig2 = makeRig(storeOccurrences(store, on: today))
        XCTAssertEqual(rig2.hiddenBlocks.count, 1, "fixture")
        let oldIDs = Set(storeOccurrences(store, on: today).map(\.id))
        made.timeRanges = [.init(start: today.addingTimeInterval(12 * 3600), end: today.addingTimeInterval(13 * 3600))]
        store.updateCalendarEvent(made)
        let newOccs = storeOccurrences(store, on: today)
        XCTAssertFalse(oldIDs.isSuperset(of: newOccs.map(\.id)), "fixture: the edit minted a new occurrence id")
        XCTAssertNotNil(EventCreationMotionRegistry.shared.mark(for: made.id), "fixture: mark still live")
        apply(rig2, newOccs)
        XCTAssertEqual(rig2.hiddenBlocks.count, 0, "an edit that re-ids the occurrence must not hold")
    }

    /// Scroll rig: a marked arrival outside the viewport has no layers when
    /// its model lands, so it is not held — and scrolling it in later never
    /// holds it. Control: the same rig with the arrival inside the viewport.
    func testAScrollOrCullBringingABlockInDoesNotHold() {
        func rig(arrivalHour: Double) -> (UIScrollView, Rig, CalendarLayout.EventOccurrence) {
            let keeper = occurrence(id: "K-\(UUID().uuidString)", hour: 1)
            let sv = UIScrollView(frame: CGRect(x: 0, y: 0, width: 360, height: 300))
            sv.contentSize = CGSize(width: 360, height: 2000)
            let host = DayLayerHostView(frame: CGRect(x: 0, y: 0, width: 360, height: 2000))
            sv.addSubview(host)
            host.apply(model([]))
            host.layoutIfNeeded()
            let r = Rig(host: host, chrome: Set((host.layer.sublayers ?? []).map(ObjectIdentifier.init)))
            apply(r, [keeper])
            let arrival = occurrence(id: "A-\(UUID().uuidString)", hour: arrivalHour)
            mark([arrival])
            apply(r, [keeper, arrival])
            return (sv, r, arrival)
        }
        let (_, ctl, _) = rig(arrivalHour: 2)
        XCTAssertEqual(ctl.blocks.count, 2, "fixture: both in the viewport")
        XCTAssertEqual(ctl.hiddenBlocks.count, 1, "control: an in-viewport arrival is held")

        let (sv, r, _) = rig(arrivalHour: 20)
        XCTAssertEqual(r.blocks.count, 1, "fixture: the arrival at 20h is culled (no layers)")
        XCTAssertEqual(r.hiddenBlocks.count, 0)
        sv.contentOffset = CGPoint(x: 0, y: 1000)
        XCTAssertTrue(r.host.debugRunCullPass())
        let arrivalY: CGFloat = 16 + 20 * 56
        XCTAssertTrue(r.blocks.contains { abs($0.frame.minY - arrivalY) < 2 }, "fixture: the cull brought the arrival in")
        XCTAssertEqual(r.hiddenBlocks.count, 0, "scrolled in: shown plainly")
    }

    /// A marked recurring series: a NEW occurrence of it appearing in a day
    /// that already showed another occurrence of the same series is not a
    /// birth. Real ids from the builder: a daily 23:00–01:00 series started
    /// yesterday has two occurrences today (yesterday's tail, today's head).
    func testANewOccurrenceOfAMarkedSeriesThatAlreadyHadABlockIsNotHeld() {
        let series = dailySeries("Night", hour: 23, duration: 2 * 3600, from: day(-1))
        let todays = CalendarLayout.occurrencesForDate([series], date: today)
        guard todays.count == 2 else { return XCTFail("fixture: expected 2 occurrences today, got \(todays.count)") }
        // Both columns are built BEFORE the mark: the rig's already-shown
        // occurrence must not itself be a held arrival.
        let ctl = makeRig([])
        let rig = makeRig([todays[0]])
        XCTAssertEqual(rig.hiddenBlocks.count, 0, "fixture")
        EventCreationMotionRegistry.shared.mark([series.id], source: .local)

        apply(ctl, todays)
        XCTAssertEqual(ctl.hiddenBlocks.count, 2, "control: a series new to the day holds every block")

        apply(rig, todays)
        XCTAssertEqual(rig.blocks.count, 2, "fixture")
        XCTAssertEqual(rig.hiddenBlocks.count, 0, "the series already had a block in this day")
    }

    // MARK: Claim 3 — every exit shows the block

    func testTheCapIsTwelveAndTheThirteenthIsShown() {
        func run(_ n: Int) -> (held: Int, blocks: Int) {
            let keeper = occurrence(id: "K-\(UUID().uuidString)", hour: 20)
            let rig = makeRig([keeper])
            let arrivals = (0..<n).map { occurrence(id: "N\($0)-\(UUID().uuidString)", hour: Double($0)) }
            mark(arrivals)
            apply(rig, [keeper] + arrivals)
            return (rig.hiddenBlocks.count, rig.blocks.count)
        }
        let twelve = run(12)
        XCTAssertEqual(twelve.blocks, 13)
        XCTAssertEqual(twelve.held, 12, "control: 12 all held")
        let thirteen = run(13)
        XCTAssertEqual(thirteen.blocks, 14)
        XCTAssertEqual(thirteen.held, 12, "the 13th is shown at once")
    }

    func testARevealRecycledMidWaitIsShownForgottenAndItsSubtreeReusedVisible() {
        let keeper = occurrence(id: "K-\(UUID().uuidString)", hour: 20)
        let rig = makeRig([keeper])
        let b = occurrence(id: "B-\(UUID().uuidString)", hour: 13)
        mark([b])
        apply(rig, [keeper, b])
        XCTAssertEqual(rig.hiddenBlocks.count, 1, "control: held off window")
        apply(rig, [keeper])
        assertClean(rig, blocks: 1, "after recycle mid-wait")
        let c = occurrence(id: "C-\(UUID().uuidString)", hour: 15)
        apply(rig, [keeper, c])
        XCTAssertEqual(rig.hiddenBlocks.count, 0, "the parked subtree is reused visible")
        attachToWindow(rig.host)
        let s = record(rig, 1.2)
        XCTAssertEqual(peak(s), 0, "a recycled reveal never plays later")
        assertClean(rig, blocks: 2)
        assertTwelveFreshHoldsFit(rig, keep: [keeper])
    }

    func testARevealRecycledMidMotionDropsEveryPieceAtOnce() {
        let keeper = occurrence(id: "K-\(UUID().uuidString)", hour: 20)
        let rig = makeRig([keeper])
        attachToWindow(rig.host)
        pump(0.5)
        let b = occurrence(id: "B-\(UUID().uuidString)", hour: 13)
        mark([b])
        apply(rig, [keeper, b])
        XCTAssertTrue(pumpUntil(1.5) { rig.createPieces.count > 0 }, "control: the motion started")
        XCTAssertEqual(rig.hiddenBlocks.count, 1, "the block is hidden while pieces show")
        apply(rig, [keeper])
        assertClean(rig, blocks: 1, "right after the mid-motion recycle")
        let s = record(rig, 1.0)
        XCTAssertEqual(peak(s), 0, "no piece reappears and nothing re-hides")
        XCTAssertTrue(s.allSatisfy { $0.hidden == 0 })
        // The subtree is reused for an unmarked block: visible.
        let c = occurrence(id: "C-\(UUID().uuidString)", hour: 15)
        apply(rig, [keeper, c])
        pump(0.8)
        assertClean(rig, blocks: 2)
        assertTwelveFreshHoldsFit(rig, keep: [keeper])
    }

    /// Mid-motion scroll-out (cull recycle) and back: shown, no pieces.
    func testARevealCulledByScrollMidMotionIsShownWhenScrolledBack() {
        let keeper = occurrence(id: "K-\(UUID().uuidString)", hour: 1)
        let sv = UIScrollView(frame: CGRect(x: 0, y: 0, width: 360, height: 400))
        sv.contentSize = CGSize(width: 360, height: 2000)
        let host = DayLayerHostView(frame: CGRect(x: 0, y: 0, width: 360, height: 2000))
        sv.addSubview(host)
        host.apply(model([]))
        host.layoutIfNeeded()
        let rig = Rig(host: host, chrome: Set((host.layer.sublayers ?? []).map(ObjectIdentifier.init)))
        apply(rig, [keeper])
        attachToWindow(sv)
        pump(0.5)
        let b = occurrence(id: "B-\(UUID().uuidString)", hour: 3)
        mark([b])
        apply(rig, [keeper, b])
        XCTAssertEqual(rig.hiddenBlocks.count, 1, "control: held")
        XCTAssertTrue(pumpUntil(1.5) { rig.createPieces.count > 0 }, "control: the motion started")
        sv.contentOffset = CGPoint(x: 0, y: 1400)
        host.debugRunCullPass()
        XCTAssertEqual(rig.createPieces.count, 0, "culled mid-motion: pieces gone")
        XCTAssertEqual(rig.hiddenBlocks.count, 0)
        sv.contentOffset = .zero
        host.debugRunCullPass()
        let s = record(rig, 1.0)
        XCTAssertEqual(peak(s), 0)
        assertClean(rig, blocks: 2, "scrolled back")
    }

    /// Stale (≥6s): the mark is 3.9s old at claim, the column stays off
    /// window 2.3s more, so the reveal is ≥6.2s old at attach and is shown
    /// AT attach (before the 0.4s settle) without playing. Control on the
    /// same rig: a fresh mark plays.
    func testAStaleRevealIsShownAtAttachWithoutPlaying() {
        func run(markAge: TimeInterval, wait: TimeInterval) -> (atAttach: Int, peak: Int, rig: Rig, keeper: CalendarLayout.EventOccurrence) {
            let keeper = occurrence(id: "K-\(UUID().uuidString)", hour: 20)
            let rig = makeRig([keeper])
            let b = occurrence(id: "B-\(UUID().uuidString)", hour: 13)
            mark([b], now: Date().addingTimeInterval(-markAge))
            apply(rig, [keeper, b])
            XCTAssertEqual(rig.hiddenBlocks.count, 1, "fixture: held (mark still inside its 4s lifetime)")
            pump(wait)
            attachToWindow(rig.host)
            let atAttach = rig.hiddenBlocks.count
            let s = record(rig, 1.5)
            assertClean(rig, blocks: 2, "markAge=\(markAge)")
            rig.host.removeFromSuperview()
            return (atAttach, peak(s), rig, keeper)
        }
        let fresh = run(markAge: 0, wait: 0.2)
        XCTAssertEqual(fresh.atAttach, 1, "control: a fresh reveal waits for the settle")
        XCTAssertGreaterThan(fresh.peak, 0, "control: a fresh reveal plays")
        let stale = run(markAge: 3.9, wait: 2.3)
        XCTAssertEqual(stale.atAttach, 0, "a stale reveal is shown at attach")
        XCTAssertEqual(stale.peak, 0, "a stale reveal never plays")
        assertTwelveFreshHoldsFit(stale.rig, keep: [stale.keeper])
    }

    /// otherDay: a cross-midnight event keeps ONE occurrence id on both
    /// days, so its held block survives the column turning to tomorrow (it
    /// is not recycled) — only the otherDay drop can show it. Off window:
    /// shown at attach, never plays. Control: no redate ⇒ plays.
    func testARevealWhoseColumnTurnedToAnotherDayIsShownWithoutPlaying() {
        let start = today.addingTimeInterval(23 * 3600)
        let late = Event(title: "Late", timeRanges: [.init(start: start, end: start.addingTimeInterval(2 * 3600))], type: "Study")
        func occ(_ d: Date) -> CalendarLayout.EventOccurrence? {
            CalendarLayout.occurrencesForDate([late], date: d).first
        }
        guard let todayOcc = occ(today), let tomorrowOcc = occ(day(1)), todayOcc.id == tomorrowOcc.id else {
            return XCTFail("fixture: a cross-midnight event shares one occurrence id across days")
        }
        func run(redate: Bool, onScreen: Bool) -> (stillHeldAfterRedate: Int, peak: Int, rig: Rig) {
            let rig = makeRig([])
            if onScreen { attachToWindow(rig.host); pump(0.5) }
            EventCreationMotionRegistry.shared.mark([late.id], source: .local)
            apply(rig, [todayOcc])
            XCTAssertEqual(rig.hiddenBlocks.count, 1, "fixture: held on today")
            if redate { apply(rig, [tomorrowOcc], date: day(1)) }
            let stillHeld = rig.hiddenBlocks.count
            XCTAssertEqual(rig.blocks.count, 1, "fixture: the block survived the redate (same id)")
            if !onScreen { attachToWindow(rig.host) }
            let s = record(rig, 1.5)
            assertClean(rig, blocks: 1, "redate=\(redate) onScreen=\(onScreen)")
            rig.host.removeFromSuperview()
            return (stillHeld, peak(s), rig)
        }
        for onScreen in [false, true] {
            let same = run(redate: false, onScreen: onScreen)
            XCTAssertGreaterThan(same.peak, 0, "control: same day plays (onScreen=\(onScreen))")
            let moved = run(redate: true, onScreen: onScreen)
            XCTAssertEqual(moved.stillHeldAfterRedate, 1, "fixture: the redate itself does not show it")
            XCTAssertEqual(moved.peak, 0, "another day: shown without playing (onScreen=\(onScreen))")
            assertTwelveFreshHoldsFit(moved.rig, keep: [])
        }
    }

    /// offWindow at play time: scheduled on screen, the column leaves the
    /// window during the settle ⇒ shown without playing, and nothing plays
    /// on re-attach. Control: stays on screen ⇒ plays.
    func testARevealWhoseColumnLeftTheWindowBeforePlayingIsShown() {
        func run(leave: Bool) -> (offPeak: Int, laterPeak: Int, rig: Rig) {
            let keeper = occurrence(id: "K-\(UUID().uuidString)", hour: 20)
            let rig = makeRig([keeper])
            attachToWindow(rig.host)
            pump(0.1)                       // inside the 0.4s attach settle
            let b = occurrence(id: "B-\(UUID().uuidString)", hour: 13)
            mark([b])
            apply(rig, [keeper, b])         // scheduled for the settle's end
            if leave { rig.host.removeFromSuperview() }
            let off = record(rig, 1.0)
            if leave { attachToWindow(rig.host) }
            let later = record(rig, 1.2)
            assertClean(rig, blocks: 2, "leave=\(leave)")
            return (peak(off), peak(later), rig)
        }
        let stay = run(leave: false)
        XCTAssertGreaterThan(stay.offPeak, 0, "control: on screen it plays")
        let left = run(leave: true)
        XCTAssertEqual(left.offPeak, 0, "off window: never plays")
        XCTAssertEqual(left.laterPeak, 0, "and does not replay at re-attach")
        assertTwelveFreshHoldsFit(left.rig, keep: [])
    }

    // MARK: Claim 4 — deferral

    func testOffWindowARevealWaitsForAttachThenTheSettle() {
        let keeper = occurrence(id: "K-\(UUID().uuidString)", hour: 20)
        let rig = makeRig([keeper])
        let b = occurrence(id: "B-\(UUID().uuidString)", hour: 13)
        mark([b])
        apply(rig, [keeper, b])
        let off = record(rig, 1.0)
        XCTAssertTrue(off.allSatisfy { $0.hidden == 1 && $0.pieces == 0 }, "off window: held, not playing")
        let t0 = CACurrentMediaTime()
        attachToWindow(rig.host)
        let s = record(rig, 2.0, origin: t0)
        guard let first = firstPieceTime(s) else { return XCTFail("it must play after attach") }
        // asyncAfter never fires early: the settle is 0.4s from didMoveToWindow,
        // which runs after t0.
        XCTAssertGreaterThanOrEqual(first, 0.39, "waits for the 0.4s attach settle")
        XCTAssertLessThan(first, 1.5)
        XCTAssertTrue(s.filter { $0.t < 0.39 }.allSatisfy { $0.hidden == 1 }, "held through the settle")
        assertClean(rig, blocks: 2)
    }

    private func coveredRig() -> (Rig, UIViewController, CalendarLayout.EventOccurrence) {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let w = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        w.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        let root = UIViewController()
        w.rootViewController = root
        w.isHidden = false
        window = w
        let keeper = occurrence(id: "K-\(UUID().uuidString)", hour: 20)
        let rig = makeRig([keeper])
        root.view.addSubview(rig.host)
        rig.host.layoutIfNeeded()
        pump(0.6)                           // past the attach settle
        return (rig, root, keeper)
    }

    /// A create saved here plays at once, under its own sheet still sliding
    /// away (the user asked for it to start on 保存).
    func testWhileCoveredALocalCreatePlaysAtOnce() {
        let (rig, root, keeper) = coveredRig()
        root.present(UIViewController(), animated: false)
        XCTAssertNotNil(root.presentedViewController, "fixture: the cover is presented")
        let b = occurrence(id: "B-\(UUID().uuidString)", hour: 13)
        mark([b], source: .local)
        apply(rig, [keeper, b])
        let s = record(rig, 1.0)
        guard let first = firstPieceTime(s) else { return XCTFail("a local create plays under the cover") }
        XCTAssertLessThan(first, 0.5)
        assertClean(rig, blocks: 2)
    }

    /// An arrival from elsewhere under some open sheet waits for it.
    func testWhileCoveredARevealWaitsAndPlaysOnceTheCoverIsGone() {
        // Control: same rig, no cover ⇒ plays within the short settle.
        do {
            let (rig, _, keeper) = coveredRig()
            let b = occurrence(id: "B-\(UUID().uuidString)", hour: 13)
            mark([b], source: .remote)
            apply(rig, [keeper, b])
            let s = record(rig, 1.0)
            XCTAssertNotNil(firstPieceTime(s), "control: uncovered it plays")
            XCTAssertLessThan(firstPieceTime(s) ?? 9, 0.5)
            rig.host.removeFromSuperview()
            window?.isHidden = true
            window = nil
        }
        let (rig, root, keeper) = coveredRig()
        let cover = UIViewController()
        root.present(cover, animated: false)
        XCTAssertNotNil(root.presentedViewController, "fixture: the cover is presented")
        let b = occurrence(id: "B-\(UUID().uuidString)", hour: 13)
        mark([b], source: .remote)
        apply(rig, [keeper, b])
        let covered = record(rig, 1.2)
        XCTAssertTrue(covered.allSatisfy { $0.hidden == 1 && $0.pieces == 0 }, "covered: held, not playing under it")
        root.dismiss(animated: false)
        XCTAssertTrue(pumpUntil(1.0) { root.presentedViewController == nil }, "fixture: dismissed")
        let after = record(rig, 1.5)
        guard let first = firstPieceTime(after) else { return XCTFail("plays once uncovered") }
        XCTAssertLessThan(first, 0.6, "picked up by the next per-frame retry")
        assertClean(rig, blocks: 2)
    }

    /// An arrival covered the whole time: per-frame retries for ~2s, then it
    /// plays under the cover anyway. asyncAfter only fires late, so the first
    /// piece is at ≥2s after the claim; the upper bound is loose for a loaded
    /// host (the stale drop would only start at 6s).
    func testWhileCoveredItRetriesForTwoSecondsThenPlaysAnyway() {
        let (rig, root, keeper) = coveredRig()
        root.present(UIViewController(), animated: false)
        XCTAssertNotNil(root.presentedViewController, "fixture: the cover is presented")
        let b = occurrence(id: "B-\(UUID().uuidString)", hour: 13)
        mark([b], source: .remote)
        let t0 = CACurrentMediaTime()
        apply(rig, [keeper, b])
        let s = record(rig, 4.5, origin: t0)
        guard let first = firstPieceTime(s) else { return XCTFail("after 20 retries it plays anyway") }
        XCTAssertGreaterThanOrEqual(first, 1.95, "not before ~2s of retries")
        XCTAssertLessThan(first, 4.0)
        assertClean(rig, blocks: 2)
    }

    // MARK: Claim 5 — burst

    private func pieceDelta(arrivals n: Int, attachFirst: Bool) -> (peak: Int, fades: Int) {
        let keeper = occurrence(id: "K-\(UUID().uuidString)", hour: 20)
        let rig = makeRig([keeper])
        if attachFirst { attachToWindow(rig.host); pump(0.5) }
        let arrivals = occs("N", hours: (0..<n).map { Double($0 * 2) })
        mark(arrivals)
        apply(rig, [keeper] + arrivals)
        if !attachFirst { attachToWindow(rig.host) }
        let s = record(rig, 2.0)
        let fades = s.reduce(into: Set<ObjectIdentifier>()) { $0.formUnion($1.fading) }.count
        assertClean(rig, blocks: n + 1, "burst n=\(n)")
        rig.host.removeFromSuperview()
        return (peak(s), fades)
    }

    func testABurstPlaysThreeFullMotionsAndFadesTheRestOnScreenAndAtAttach() {
        for attachFirst in [true, false] {
            let one = pieceDelta(arrivals: 1, attachFirst: attachFirst)
            XCTAssertGreaterThan(one.peak, 10, "control: one arrival assembles from grains")
            XCTAssertEqual(one.fades, 0)
            let three = pieceDelta(arrivals: 3, attachFirst: attachFirst)
            XCTAssertEqual(three.peak, 3 * one.peak, "three full motions")
            XCTAssertEqual(three.fades, 0)
            let five = pieceDelta(arrivals: 5, attachFirst: attachFirst)
            XCTAssertEqual(five.peak, 3 * one.peak, "only three play the variant (attachFirst=\(attachFirst))")
            XCTAssertEqual(five.fades, 2, "the 4th and 5th fade (attachFirst=\(attachFirst))")
        }
    }

    /// On screen: three playing, then a 4th arrives in a later pass ⇒ it
    /// fades. Control on the same rig: after the three landed, a 4th plays.
    func testAFourthArrivalWhileThreeArePlayingFadesOnScreen() {
        func run(wait: TimeInterval) -> (fourthFaded: Bool, fourthPeak: Int, fourthHadMotion: Bool) {
            let keeper = occurrence(id: "K-\(UUID().uuidString)", hour: 20)
            let rig = makeRig([keeper])
            attachToWindow(rig.host)
            pump(0.5)
            let three = occs("T", hours: [0, 2, 4])
            mark(three)
            apply(rig, [keeper] + three)
            XCTAssertTrue(pumpUntil(1.0) { rig.createPieces.count > 0 }, "fixture: the three are playing")
            if wait > 0 { pump(wait) }
            let before = Set(rig.hiddenBlocks.map(ObjectIdentifier.init))
            let fourth = occurrence(id: "F-\(UUID().uuidString)", hour: 8)
            mark([fourth])
            apply(rig, [keeper] + three + [fourth])
            let fourthIDs = Set(rig.hiddenBlocks.map(ObjectIdentifier.init)).subtracting(before)
            XCTAssertEqual(fourthIDs.count, 1, "fixture: the 4th is held")
            let s = record(rig, 1.8)
            let faded = s.contains { !$0.fading.isDisjoint(with: fourthIDs) }
            // Pieces while the three are gone: the 4th's own motion.
            let piecesAfterThree = wait > 0 ? peak(s) : 0
            assertClean(rig, blocks: 5, "wait=\(wait)")
            rig.host.removeFromSuperview()
            return (faded, piecesAfterThree, wait > 0 && peak(s) > 0)
        }
        let busy = run(wait: 0)
        XCTAssertTrue(busy.fourthFaded, "three in flight ⇒ the 4th fades")
        let idle = run(wait: 1.2)
        XCTAssertFalse(idle.fourthFaded, "control: the three landed ⇒ the 4th plays the variant")
        XCTAssertTrue(idle.fourthHadMotion)
    }

    /// At attach: three playing on screen, the column leaves and comes back
    /// with a 4th held off window — the three still in flight count.
    func testRevealsStillPlayingCountTowardTheBurstAtAttach() {
        func run(waitBeforeLeaving: TimeInterval) -> Bool {
            let keeper = occurrence(id: "K-\(UUID().uuidString)", hour: 20)
            let rig = makeRig([keeper])
            attachToWindow(rig.host)
            pump(0.5)
            let three = occs("T", hours: [0, 2, 4])
            mark(three)
            apply(rig, [keeper] + three)
            XCTAssertTrue(pumpUntil(1.0) { rig.createPieces.count > 0 }, "fixture: the three are playing")
            if waitBeforeLeaving > 0 { pump(waitBeforeLeaving) }
            rig.host.removeFromSuperview()
            let before = Set(rig.hiddenBlocks.map(ObjectIdentifier.init))
            let fourth = occurrence(id: "F-\(UUID().uuidString)", hour: 8)
            mark([fourth])
            apply(rig, [keeper] + three + [fourth])
            let fourthIDs = Set(rig.hiddenBlocks.map(ObjectIdentifier.init)).subtracting(before)
            XCTAssertEqual(fourthIDs.count, 1, "fixture: the 4th is held off window")
            attachToWindow(rig.host)
            let s = record(rig, 1.8)
            assertClean(rig, blocks: 5, "wait=\(waitBeforeLeaving)")
            rig.host.removeFromSuperview()
            return s.contains { !$0.fading.isDisjoint(with: fourthIDs) }
        }
        XCTAssertTrue(run(waitBeforeLeaving: 0), "three still in flight at attach ⇒ the 4th fades")
        XCTAssertFalse(run(waitBeforeLeaving: 1.2), "control: the three landed ⇒ the 4th plays the variant")
    }

    // MARK: Claim 6 — store

    func testStoreInternalInsertsDoNotMarkAndTheInterruptCreateDoes() {
        let store = makeStore()
        let plain = plainEvent("Plain", hour: 6)
        store.addCalendarEvent(plain)
        XCTAssertNil(EventCreationMotionRegistry.shared.mark(for: plain.id), "the default add stays plain")

        let series = dailySeries("Daily", hour: 9)
        store.addCalendarEvent(series)
        var known = Set(store.rawCalendarEvents.map(\.id))
        store.applyRecurringEdit(
            seriesEvent: store.findCalendarEvent(id: series.id)!, occurrenceDate: day(1), scope: .single
        ) { $0.title = "Exception" }
        let exceptionRows = store.rawCalendarEvents.filter { !known.contains($0.id) }
        XCTAssertEqual(exceptionRows.count, 1, "fixture: .single minted one exception instance")
        XCTAssertTrue(exceptionRows.allSatisfy { EventCreationMotionRegistry.shared.mark(for: $0.id) == nil },
                      "an exception instance is not a creation")

        known = Set(store.rawCalendarEvents.map(\.id))
        store.applyRecurringEdit(
            seriesEvent: store.findCalendarEvent(id: series.id)!, occurrenceDate: day(3), scope: .following
        ) { $0.title = "Split" }
        let splitRows = store.rawCalendarEvents.filter { !known.contains($0.id) }
        XCTAssertEqual(splitRows.count, 1, "fixture: .following minted a new series")
        XCTAssertTrue(splitRows.allSatisfy { EventCreationMotionRegistry.shared.mark(for: $0.id) == nil },
                      "a series split is not a creation")
        XCTAssertNil(EventCreationMotionRegistry.shared.mark(for: series.id))

        // Control in the same store: the interrupt create marks .local.
        let parent = plainEvent("Parent", hour: 14)
        store.addCalendarEvent(parent)
        let interrupt = store.createInterrupt(
            parentEvent: store.findCalendarEvent(id: parent.id)!,
            occurrenceDate: today,
            title: "Interrupt",
            timeRange: .init(start: today.addingTimeInterval(14.25 * 3600), end: today.addingTimeInterval(14.5 * 3600))
        )
        guard let interrupt else { return XCTFail("fixture: interrupt created") }
        XCTAssertEqual(EventCreationMotionRegistry.shared.mark(for: interrupt.id)?.source, .local)
    }

    func testSampleSeedingMarksNothing() {
        let store = makeStore(seeds: true)
        XCTAssertFalse(store.rawCalendarEvents.isEmpty, "fixture: samples were seeded")
        XCTAssertTrue(store.rawCalendarEvents.allSatisfy { EventCreationMotionRegistry.shared.mark(for: $0.id) == nil })
        let made = plainEvent("Made")
        store.addCalendarEvent(made, creationMotion: .local)
        XCTAssertNotNil(EventCreationMotionRegistry.shared.mark(for: made.id), "control: an opted-in add marks")
    }

    // MARK: Claim 7 — remote

    /// The import threshold counts ARRIVALS (unseen, non-exception rows),
    /// not the page: 8 arrivals riding with 9 known rows and 5 exceptions
    /// all mark; 9 arrivals mark none.
    func testTheImportThresholdCountsOnlyArrivals() {
        let store = makeStore()
        let knownRows = (0..<9).map { plainEvent("K\($0)", hour: Double($0)) }
        knownRows.forEach { store.addCalendarEvent($0) }
        func exceptions(_ n: Int) -> [Event] {
            (0..<n).map { i -> Event in
                var e = plainEvent("X\(i)", hour: 20)
                e.recurrenceParentId = UUID()
                return e
            }
        }
        let r = EventCreationMotionRegistry.shared
        let eight = (0..<8).map { plainEvent("A\($0)", hour: 10) }
        let ex = exceptions(5)
        store.applyRemoteCalendarRows(adopts: knownRows + eight + ex, deletions: [])
        XCTAssertTrue(eight.allSatisfy { r.mark(for: $0.id)?.source == .remote },
                      "8 arrivals in a 22-row page still play")
        XCTAssertTrue(knownRows.allSatisfy { r.mark(for: $0.id) == nil })
        XCTAssertTrue(ex.allSatisfy { r.mark(for: $0.id) == nil })

        let nine = (0..<9).map { plainEvent("B\($0)", hour: 11) }
        store.applyRemoteCalendarRows(adopts: nine, deletions: [])
        XCTAssertTrue(nine.allSatisfy { r.mark(for: $0.id) == nil }, "9 arrivals: an import, none play")
    }

    /// A row adopted once is known: re-adopting it (an echo, an update)
    /// does not re-mark it — its mark keeps its first timestamp.
    func testAReAdoptedRowIsNotMarkedAgain() {
        let store = makeStore()
        let row = plainEvent("Row")
        store.applyRemoteCalendarRows(adopts: [row], deletions: [])
        guard let first = EventCreationMotionRegistry.shared.mark(for: row.id) else { return XCTFail("control: marked") }
        pump(0.05)
        var edited = row
        edited.title = "Row, renamed"
        store.applyRemoteCalendarRows(adopts: [edited], deletions: [])
        XCTAssertEqual(EventCreationMotionRegistry.shared.mark(for: row.id)?.at, first.at, "not re-marked")
    }

    // MARK: Claim 8 — delete while held / mid-reveal

    /// Negative control for the snapshot observable: a hidden layer
    /// snapshots fully transparent, a shown one does not.
    func testTheSnapshotObservableHasTeeth() {
        let l = CALayer()
        l.frame = CGRect(x: 0, y: 0, width: 100, height: 40)
        l.backgroundColor = UIColor.systemBlue.cgColor
        l.isHidden = true
        XCTAssertEqual(maxAlpha(EventDeletionMotion.snapshot(l)), 0, "hidden ⇒ transparent snapshot")
        l.isHidden = false
        XCTAssertGreaterThan(maxAlpha(EventDeletionMotion.snapshot(l)) ?? 0, 200)
    }

    private func assertGhostPlaysTheBlock(_ rig: Rig, keeperCount: Int, file: StaticString = #filePath, line: UInt = #line) {
        var alphas: [UInt8] = []
        var createSeen = 0
        let end = Date().addingTimeInterval(2.0)
        while Date() < end {
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
            createSeen = max(createSeen, rig.createPieces.count)
            XCTAssertEqual(rig.hiddenBlocks.count, 0, "no hidden ghost", file: file, line: line)
            if alphas.isEmpty, let tile = rig.deletePieces.first, let a = maxAlpha(tile.contents) { alphas.append(a) }
        }
        XCTAssertEqual(createSeen, 0, "no create piece after the delete", file: file, line: line)
        XCTAssertFalse(alphas.isEmpty, "the delete motion played", file: file, line: line)
        XCTAssertGreaterThan(alphas.first ?? 0, 200, "the ghost snapshot shows the block, not a hidden layer",
                             file: file, line: line)
        assertClean(rig, blocks: keeperCount, "after the ghost", file: file, line: line)
    }

    func testABlockDeletedWhileHeldGhostsVisiblyAndLeavesNothing() {
        EventDeletionMotionRegistry.shared.isEnabled = { true }
        let keeper = occurrence(id: "K-\(UUID().uuidString)", hour: 20)
        let rig = makeRig([keeper])
        let b = occurrence(id: "B-\(UUID().uuidString)", hour: 13)
        mark([b])
        apply(rig, [keeper, b])
        XCTAssertEqual(rig.hiddenBlocks.count, 1, "control: held")
        EventDeletionMotionRegistry.shared.mark([b.event.id], source: .local)
        apply(rig, [keeper])
        XCTAssertEqual(rig.blocks.count, 2, "fixture: the deleted block stays as a ghost")
        XCTAssertEqual(rig.hiddenBlocks.count, 0, "the ghost is shown, not left hidden")
        attachToWindow(rig.host)
        assertGhostPlaysTheBlock(rig, keeperCount: 1)
        assertTwelveFreshHoldsFit(rig, keep: [keeper])
    }

    func testABlockDeletedMidRevealGhostsVisiblyAndLeavesNoPiece() {
        EventDeletionMotionRegistry.shared.isEnabled = { true }
        for variant in EventCreationMotionVariant.allCases {
            setVariant(variant)
            let keeper = occurrence(id: "K-\(UUID().uuidString)", hour: 20)
            let rig = makeRig([keeper])
            attachToWindow(rig.host)
            pump(0.5)
            let b = occurrence(id: "B-\(UUID().uuidString)", hour: 13)
            mark([b])
            apply(rig, [keeper, b])
            XCTAssertTrue(pumpUntil(1.5) { rig.createPieces.count > 0 }, "control: \(variant) started")
            EventDeletionMotionRegistry.shared.mark([b.event.id], source: .local)
            apply(rig, [keeper])
            XCTAssertEqual(rig.createPieces.count, 0, "\(variant): create pieces gone with the delete")
            XCTAssertEqual(rig.hiddenBlocks.count, 0, "\(variant): the ghost is shown")
            assertGhostPlaysTheBlock(rig, keeperCount: 1)
            rig.host.removeFromSuperview()
        }
    }

    // MARK: Claim 9 — variants land on the block

    func testEveryVariantLandsOnTheBlockAtItsOwnOpacityOnTheHost() {
        for variant in EventCreationMotionVariant.allCases {
            for done in [false, true] {
                setVariant(variant)
                let keeper = occurrence(id: "K-\(UUID().uuidString)", hour: 20)
                let rig = makeRig([keeper])
                attachToWindow(rig.host)
                pump(0.5)
                var b = occurrence(id: "B-\(UUID().uuidString)", hour: 13)
                if done {
                    var e = b.event
                    e.kind = .todo
                    e.isDone = true
                    b = CalendarLayout.EventOccurrence(id: b.id, event: e, range: b.range)
                }
                let others = Set(rig.blocks.map(ObjectIdentifier.init))
                mark([b])
                apply(rig, [keeper, b])
                guard let block = rig.blocks.first(where: { !others.contains(ObjectIdentifier($0)) }) else {
                    XCTFail("fixture: block"); continue
                }
                let expected: Float = done ? 0.55 : 1.0
                XCTAssertEqual(block.opacity, expected, accuracy: 0.001, "fixture: \(variant) done=\(done) opacity")
                XCTAssertTrue(block.isHidden, "held")
                let s = record(rig, 1.5)
                let label = "\(variant) done=\(done)"
                XCTAssertGreaterThan(peak(s), 0, "\(label): pieces played")
                // From the first piece on: never both (block shown under its
                // pieces) and never neither (a gap before the block shows).
                if let i = s.firstIndex(where: { $0.pieces > 0 }) {
                    for sample in s[i...] {
                        XCTAssertFalse(sample.pieces > 0 && sample.hidden == 0, "\(label): block shown under its pieces")
                        XCTAssertFalse(sample.pieces == 0 && sample.hidden == 1, "\(label): a frame with neither")
                    }
                }
                XCTAssertFalse(block.isHidden, "\(label): shown")
                XCTAssertEqual(block.opacity, expected, accuracy: 0.001, "\(label): its own opacity")
                XCTAssertNil(block.animation(forKey: "createMotion"), label)
                assertClean(rig, blocks: 2, label)
                rig.host.removeFromSuperview()
            }
        }
    }

    /// `EventCreationMotion.play` directly, every variant plus lightweight,
    /// at opacity 1 and 0.55: completion runs once, the block is shown at
    /// its own opacity, the parent holds only the block again.
    func testPlayDirectlyEndsShownAtOwnOpacityWithEveryAddedLayerRemoved() {
        for variant in EventCreationMotionVariant.allCases {
            for lightweight in [false, true] {
                for opacity: Float in [1, 0.55] {
                    let parent = CALayer()
                    parent.frame = CGRect(x: 0, y: 0, width: 360, height: 400)
                    let block = CALayer()
                    block.frame = CGRect(x: 8, y: 100, width: 300, height: 56)
                    block.backgroundColor = UIColor.systemTeal.cgColor
                    block.cornerRadius = 4
                    block.opacity = opacity
                    block.isHidden = true
                    parent.addSublayer(block)
                    var completions = 0
                    var peakSublayers = 1
                    let (_, playback) = EventCreationMotion.play(
                        variant, block: block, tint: .systemTeal, lightweight: lightweight
                    ) { completions += 1 }
                    let label = "\(variant) lightweight=\(lightweight) opacity=\(opacity)"
                    let end = Date().addingTimeInterval(1.2)
                    while Date() < end {
                        RunLoop.main.run(until: Date().addingTimeInterval(0.005))
                        peakSublayers = max(peakSublayers, parent.sublayers?.count ?? 0)
                    }
                    XCTAssertEqual(completions, 1, label)
                    XCTAssertFalse(block.isHidden, label)
                    XCTAssertEqual(block.opacity, opacity, accuracy: 0.0001, label)
                    XCTAssertEqual(parent.sublayers?.count, 1, "\(label): every added layer removed")
                    XCTAssertTrue(parent.sublayers?.first === block, label)
                    XCTAssertTrue(playback.layers.isEmpty, label)
                    if lightweight {
                        XCTAssertEqual(peakSublayers, 1, "\(label): a fade adds no layer")
                    } else {
                        XCTAssertGreaterThan(peakSublayers, 1, "\(label): pieces were added")
                    }
                }
            }
        }
    }

    func testPlayDegenerateCasesStillShowTheBlock() {
        // No superlayer: shown and completed synchronously.
        let orphan = CALayer()
        orphan.frame = CGRect(x: 0, y: 0, width: 100, height: 40)
        orphan.isHidden = true
        var done = 0
        _ = EventCreationMotion.play(.assemble, block: orphan, tint: .red) { done += 1 }
        XCTAssertEqual(done, 1)
        XCTAssertFalse(orphan.isHidden)
        // A sliver (height < 2): fades, adds nothing, shown.
        let parent = CALayer()
        let sliver = CALayer()
        sliver.frame = CGRect(x: 0, y: 0, width: 100, height: 1)
        sliver.isHidden = true
        sliver.opacity = 0.55
        parent.addSublayer(sliver)
        var done2 = 0
        _ = EventCreationMotion.play(.crtOn, block: sliver, tint: .red) { done2 += 1 }
        XCTAssertFalse(sliver.isHidden)
        XCTAssertEqual(parent.sublayers?.count, 1)
        pump(0.5)
        XCTAssertEqual(done2, 1)
        XCTAssertEqual(sliver.opacity, 0.55, accuracy: 0.0001)
    }

    /// A cancelled playback (the host recycled the block) removes its pieces
    /// at once and never calls completion or re-hides.
    func testACancelledPlaybackRemovesPiecesAndNeverCompletes() {
        for variant in EventCreationMotionVariant.allCases {
            let parent = CALayer()
            let block = CALayer()
            block.frame = CGRect(x: 8, y: 100, width: 300, height: 56)
            block.backgroundColor = UIColor.systemTeal.cgColor
            block.isHidden = true
            parent.addSublayer(block)
            var done = 0
            let (_, playback) = EventCreationMotion.play(variant, block: block, tint: .systemTeal) { done += 1 }
            XCTAssertGreaterThan(parent.sublayers?.count ?? 0, 1, "\(variant): pieces added")
            playback.cancel()
            XCTAssertEqual(parent.sublayers?.count, 1, "\(variant): pieces removed at cancel")
            block.isHidden = false          // the host shows it
            pump(1.0)
            XCTAssertEqual(done, 0, "\(variant): no completion after cancel")
            XCTAssertFalse(block.isHidden)
            XCTAssertEqual(parent.sublayers?.count, 1)
        }
    }
}
