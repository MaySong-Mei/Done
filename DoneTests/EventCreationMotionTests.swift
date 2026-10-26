//
//  EventCreationMotionTests.swift
//  DoneTests
//
//  The create-motion spike's load-bearing claims:
//    1. A block is held back for its create motion ONLY when its event was
//       marked created AND had no block in the same day's previous model —
//       an unmarked arrival, a first render, another day, or an edit that
//       re-ids an occurrence shows plainly. Each held test runs beside its
//       plain twin, so a host that holds everything, or nothing, fails.
//    2. Every way out shows the block again (played, recycled, dropped).
//    3. Only creations are marked: the store's own inserts, imports and
//       exception instances are not. Off is king's shape.
//

import XCTest
import UIKit
@testable import Done

@MainActor
final class EventCreationMotionTests: XCTestCase {

    private var savedIsEnabled: (() -> Bool)!
    private var savedVariant: Any?
    private var window: UIWindow?
    private var suiteName: String!
    private let variantKey = SpikeFeatureFlag.variantKey(EventCreationMotionFlag.spikeID)

    override func setUp() {
        super.setUp()
        savedIsEnabled = EventCreationMotionRegistry.shared.isEnabled
        EventCreationMotionRegistry.shared.isEnabled = { true }
        savedVariant = UserDefaults.standard.object(forKey: variantKey)
        UserDefaults.standard.set(EventCreationMotionVariant.assemble.rawValue, forKey: variantKey)
        suiteName = "EventCreationMotionTests-\(UUID().uuidString)"
    }

    override func tearDown() {
        EventCreationMotionRegistry.shared.isEnabled = savedIsEnabled
        if let savedVariant {
            UserDefaults.standard.set(savedVariant, forKey: variantKey)
        } else {
            UserDefaults.standard.removeObject(forKey: variantKey)
        }
        window?.isHidden = true
        window = nil
        TestStorage.tearDown(suiteName)
        super.tearDown()
    }

    private func makeStore() -> EventStore {
        EventStore(
            defaults: UserDefaults(suiteName: suiteName)!,
            storage: TestStorage.reset(suiteName),
            seedsSampleDataIfEmpty: false
        )
    }

    // MARK: Registry

    func testAMarkExpiresAfterItsLifetimeAndIsNotConsumed() {
        let registry = EventCreationMotionRegistry()
        registry.isEnabled = { true }
        let id = UUID()
        let t0 = Date()
        registry.mark([id], source: .remote, now: t0)
        XCTAssertEqual(registry.mark(for: id, now: t0)?.source, .remote)
        XCTAssertNotNil(registry.mark(for: id, now: t0), "a second host still reads it")
        XCTAssertNotNil(registry.mark(for: id, now: t0.addingTimeInterval(EventCreationMotionRegistry.lifetime - 0.01)))
        XCTAssertNil(registry.mark(for: id, now: t0.addingTimeInterval(EventCreationMotionRegistry.lifetime)))
    }

    func testFlagOffMarksNothing() {
        let registry = EventCreationMotionRegistry()
        registry.isEnabled = { false }
        let id = UUID()
        registry.mark([id], source: .local)
        XCTAssertNil(registry.mark(for: id))
    }

    // MARK: Store

    func testOnlyAnOptedInAddMarks() {
        let store = makeStore()
        let plain = Event(title: "plain", timeRanges: [range(hour: 9)])
        let created = Event(title: "created", timeRanges: [range(hour: 11)])
        store.addCalendarEvent(plain)
        store.addCalendarEvent(created, creationMotion: .local)
        XCTAssertNil(EventCreationMotionRegistry.shared.mark(for: plain.id), "store-internal adds stay plain")
        XCTAssertEqual(EventCreationMotionRegistry.shared.mark(for: created.id)?.source, .local)
    }

    func testRemoteArrivalsAreMarkedButNotKnownRowsExceptionsOrImports() {
        let store = makeStore()
        let known = Event(title: "known", timeRanges: [range(hour: 8)])
        store.addCalendarEvent(known)
        var edited = known
        edited.title = "known, edited elsewhere"
        let arrival = Event(title: "new elsewhere", timeRanges: [range(hour: 10)])
        var exception = Event(title: "exception", timeRanges: [range(hour: 12)])
        exception.recurrenceParentId = UUID()

        store.applyRemoteCalendarRows(adopts: [edited, arrival, exception], deletions: [])
        XCTAssertEqual(EventCreationMotionRegistry.shared.mark(for: arrival.id)?.source, .remote)
        XCTAssertNil(EventCreationMotionRegistry.shared.mark(for: known.id), "an update is not a creation")
        XCTAssertNil(EventCreationMotionRegistry.shared.mark(for: exception.id), "an edit mints exceptions")

        let limit = EventCreationMotionRegistry.maxRemoteArrivals
        let atLimit = (0..<limit).map { Event(title: "a\($0)", timeRanges: [range(hour: 13)]) }
        store.applyRemoteCalendarRows(adopts: atLimit, deletions: [])
        XCTAssertTrue(atLimit.allSatisfy { EventCreationMotionRegistry.shared.mark(for: $0.id) != nil },
                      "control: a page of exactly the limit still plays")
        let importPage = (0...limit).map { Event(title: "i\($0)", timeRanges: [range(hour: 14)]) }
        store.applyRemoteCalendarRows(adopts: importPage, deletions: [])
        XCTAssertTrue(importPage.allSatisfy { EventCreationMotionRegistry.shared.mark(for: $0.id) == nil },
                      "one more is an import: none play")
    }

    // MARK: Host — who is held

    func testAMarkedArrivalIsHeldAndTheSameArrivalUnmarkedIsNot() {
        let (host, a) = makeHostWithOneBlock()
        let b = makeOccurrence(id: "B-\(UUID().uuidString)", startHour: 13)
        EventCreationMotionRegistry.shared.mark([b.event.id], source: .local)
        host.apply(makeModel([a, b]))
        host.layoutIfNeeded()
        XCTAssertEqual(hiddenCount(host), 1, "off window the held block waits, hidden")

        let (twin, a2) = makeHostWithOneBlock()
        let c = makeOccurrence(id: "C-\(UUID().uuidString)", startHour: 13)
        twin.apply(makeModel([a2, c]))
        twin.layoutIfNeeded()
        XCTAssertEqual(hiddenCount(twin), 0, "unmarked: shown at once")
    }

    func testAnEditThatReIdsAMarkedEventsBlockIsNotHeld() {
        // Created a moment ago and then edited (the AI fills in a time): the
        // event already had a block in this day, so the new id is no birth.
        let (host, a) = makeHostWithOneBlock()
        EventCreationMotionRegistry.shared.mark([a.event.id], source: .local)
        let moved = CalendarLayout.EventOccurrence(
            id: "\(a.id)-moved", event: a.event,
            range: Event.TimeRange(start: a.range.start.addingTimeInterval(3600), end: a.range.end.addingTimeInterval(3600))
        )
        host.apply(makeModel([moved]))
        host.layoutIfNeeded()
        XCTAssertEqual(hiddenCount(host), 0)
    }

    func testAFirstRenderAndAnotherDayAreNotHeld() {
        let b = makeOccurrence(id: "B-\(UUID().uuidString)", startHour: 13)
        EventCreationMotionRegistry.shared.mark([b.event.id], source: .local)
        let fresh = DayLayerHostView(frame: CGRect(x: 0, y: 0, width: 360, height: 2000))
        hiddenBaseline[ObjectIdentifier(fresh)] = makeHost().layer.sublayers?.filter(\.isHidden).count ?? 0
        fresh.apply(makeModel([b]))
        fresh.layoutIfNeeded()
        XCTAssertEqual(hiddenCount(fresh), 0, "a column mounted after the create shows it plainly")

        let (host, a) = makeHostWithOneBlock(on: day.addingTimeInterval(-86_400))
        host.apply(makeModel([a, b]))
        host.layoutIfNeeded()
        XCTAssertEqual(hiddenCount(host), 0, "the column turned to another day")
    }

    // MARK: Host — every way out shows the block

    func testARecycledHeldBlockIsShownWhenItsSubtreeIsReused() {
        let (host, a) = makeHostWithOneBlock()
        let b = makeOccurrence(id: "B-\(UUID().uuidString)", startHour: 13)
        EventCreationMotionRegistry.shared.mark([b.event.id], source: .local)
        host.apply(makeModel([a, b]))
        host.layoutIfNeeded()
        XCTAssertEqual(hiddenCount(host), 1)

        host.apply(makeModel([a]))     // b's subtree parks in the free pool…
        host.layoutIfNeeded()
        let c = makeOccurrence(id: "C-\(UUID().uuidString)", startHour: 15)
        host.apply(makeModel([a, c]))  // …and is reused for an unmarked block.
        host.layoutIfNeeded()
        XCTAssertEqual(hiddenCount(host), 0)
    }

    func testOnScreenTheMotionPlaysAndLandsOnTheBlock() {
        let (host, a) = makeHostWithOneBlock()
        attach(host)
        pump(0.6)
        let before = host.layer.sublayers?.count ?? 0
        let b = makeOccurrence(id: "B-\(UUID().uuidString)", startHour: 13)
        EventCreationMotionRegistry.shared.mark([b.event.id], source: .local)
        host.apply(makeModel([a, b]))
        host.layoutIfNeeded()
        XCTAssertEqual(hiddenCount(host), 1)

        let peak = pump(1.5, sampling: host)
        XCTAssertGreaterThan(peak, before + 1, "grains were added over the day")
        XCTAssertEqual(hiddenCount(host), 0, "the block is shown when the motion lands")
        XCTAssertEqual(host.layer.sublayers?.count ?? 0, before + 1, "and every grain is gone")
    }

    // MARK: Host — the drag-create draft turns into its block

    func testASavedDraftStaysUntilItsBlockTurnsOutOfItAndACancelledOneGoesAtOnce() {
        // Saved: the mark lands, the form's range clears, the block comes a
        // pass later — the box stays drawn through all of it.
        let (host, a) = makeHostWithOneBlock()
        attach(host)
        pump(0.6)
        let b = makeOccurrence(id: "B-\(UUID().uuidString)", startHour: 13)
        host.apply(makeModel([a], draft: b.range))
        host.layoutIfNeeded()
        XCTAssertEqual(draftLayersShown(host), 2, "control: the open form's draft is drawn")
        let before = host.layer.sublayers?.count ?? 0
        EventCreationMotionRegistry.shared.mark([b.event.id], source: .local)
        host.apply(makeModel([a]))
        host.layoutIfNeeded()
        XCTAssertEqual(draftLayersShown(host), 2, "saved: the box outlives the form")
        host.apply(makeModel([a, b]))
        host.layoutIfNeeded()
        XCTAssertEqual(hiddenCount(host) - hiddenPreviewLayers(host), 1, "its block waits under it")

        var sawMorph = false
        let end = Date().addingTimeInterval(1.2)
        while Date() < end {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            if (host.layer.sublayers?.count ?? 0) == before + 3 { sawMorph = true
                XCTAssertEqual(draftLayersShown(host), 0, "the draft hides as the morph takes its place")
            }
        }
        XCTAssertTrue(sawMorph, "two morph pieces (draft + block) played over the new block's own layer")
        XCTAssertEqual(draftLayersShown(host), 0)
        XCTAssertEqual(hiddenCount(host) - hiddenPreviewLayers(host), 0, "the block is shown")
        XCTAssertEqual(host.layer.sublayers?.count ?? 0, before + 1, "and the pieces are gone: only the block is new")

        // Cancelled twin: no mark — the box goes with the form.
        let (twin, a2) = makeHostWithOneBlock()
        let c = makeOccurrence(id: "C-\(UUID().uuidString)", startHour: 13)
        twin.apply(makeModel([a2], draft: c.range))
        twin.layoutIfNeeded()
        XCTAssertEqual(draftLayersShown(twin), 2)
        pump(EventCreationMotionRegistryTestWindow.pastSaveWindow)
        twin.apply(makeModel([a2]))
        twin.layoutIfNeeded()
        XCTAssertEqual(draftLayersShown(twin), 0)
    }

    func testABlockArrivingWhileTheFormIsStillUpTakesTheDraftToo() {
        let (host, a) = makeHostWithOneBlock()
        let b = makeOccurrence(id: "B-\(UUID().uuidString)", startHour: 13)
        host.apply(makeModel([a], draft: b.range))
        host.layoutIfNeeded()
        EventCreationMotionRegistry.shared.mark([b.event.id], source: .local)
        host.apply(makeModel([a, b], draft: b.range))
        host.layoutIfNeeded()
        host.apply(makeModel([a, b]))
        host.layoutIfNeeded()
        pump(EventCreationMotionRegistryTestWindow.pastUnclaimedTimeout)
        XCTAssertEqual(draftLayersShown(host), 2, "claimed: kept past the unclaimed timeout, until it plays")
    }

    func testAFrozenDraftNoBlockClaimsIsDropped() {
        let (host, a) = makeHostWithOneBlock()
        let b = makeOccurrence(id: "B-\(UUID().uuidString)", startHour: 13)
        host.apply(makeModel([a], draft: b.range))
        host.layoutIfNeeded()
        // Saved to another day: marked, but this column never gets a block.
        EventCreationMotionRegistry.shared.mark([UUID()], source: .local)
        host.apply(makeModel([a]))
        host.layoutIfNeeded()
        XCTAssertEqual(draftLayersShown(host), 2)
        pump(EventCreationMotionRegistryTestWindow.pastUnclaimedTimeout)
        XCTAssertEqual(draftLayersShown(host), 0)
    }

    // MARK: Fixtures

    private enum EventCreationMotionRegistryTestWindow {
        /// Past the host's 1s save window / 0.6s unclaimed timeout.
        static let pastSaveWindow: TimeInterval = 1.1
        static let pastUnclaimedTimeout: TimeInterval = 0.8
    }

    /// The draft's fill + outline (z 90, shape layers) that are showing.
    private func draftLayersShown(_ host: DayLayerHostView) -> Int {
        host.layer.sublayers?.filter { $0 is CAShapeLayer && $0.zPosition == 90 && !$0.isHidden }.count ?? 0
    }

    /// Draft layers hidden beyond the baseline (they start hidden): a shown
    /// draft lowers the hidden count by its visible layers.
    private func hiddenPreviewLayers(_ host: DayLayerHostView) -> Int {
        -(host.layer.sublayers?.filter { ($0.zPosition == 90 || $0.zPosition == 91) && !$0.isHidden }.count ?? 0)
    }

    private var day: Date { Calendar.current.startOfDay(for: Date()) }

    private func range(hour: Double) -> Event.TimeRange {
        let start = day.addingTimeInterval(hour * 3600)
        return Event.TimeRange(start: start, end: start.addingTimeInterval(3600))
    }

    /// Hidden sublayers beyond the ones the host keeps hidden anyway (the
    /// now line, the drag/creation previews…), counted when it was built.
    private var hiddenBaseline: [ObjectIdentifier: Int] = [:]

    private func hiddenCount(_ host: DayLayerHostView) -> Int {
        let hidden = host.layer.sublayers?.filter(\.isHidden).count ?? 0
        return hidden - (hiddenBaseline[ObjectIdentifier(host)] ?? 0)
    }

    private func makeHost() -> DayLayerHostView {
        let host = DayLayerHostView(frame: CGRect(x: 0, y: 0, width: 360, height: 2000))
        host.apply(makeModel([]))
        host.layoutIfNeeded()
        hiddenBaseline[ObjectIdentifier(host)] = host.layer.sublayers?.filter(\.isHidden).count ?? 0
        return host
    }

    private func attach(_ host: DayLayerHostView) {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let w = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        w.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        w.isHidden = false
        window = w
        w.addSubview(host)
        host.layoutIfNeeded()
    }

    @discardableResult
    private func pump(_ seconds: TimeInterval, sampling host: DayLayerHostView? = nil) -> Int {
        let end = Date().addingTimeInterval(seconds)
        var peak = host?.layer.sublayers?.count ?? 0
        while Date() < end {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            if let host { peak = max(peak, host.layer.sublayers?.count ?? 0) }
        }
        return peak
    }

    private func makeHostWithOneBlock(on date: Date? = nil) -> (DayLayerHostView, CalendarLayout.EventOccurrence) {
        let a = makeOccurrence(id: "A-\(UUID().uuidString)", startHour: 9)
        let host = makeHost()
        host.apply(makeModel([a], on: date))
        host.layoutIfNeeded()
        return (host, a)
    }

    private func makeOccurrence(id: String, startHour: Double) -> CalendarLayout.EventOccurrence {
        let r = range(hour: startHour)
        return CalendarLayout.EventOccurrence(id: id, event: Event(title: id, timeRanges: [r], type: "Study"), range: r)
    }

    private func makeModel(
        _ occurrences: [CalendarLayout.EventOccurrence], on date: Date? = nil, draft: Event.TimeRange? = nil
    ) -> DayLayerHostView.Model {
        var model = DayLayerHostView.Model(
            date: date ?? day,
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
        model.creationPreviewRange = draft
        return model
    }
}
