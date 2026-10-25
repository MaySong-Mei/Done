import XCTest
@testable import Done

/// Wrist commands against a real (isolated) EventStore, and the bridge's
/// idempotency around them.
final class WristCommandApplierTests: XCTestCase {
    private let suiteName = "WristCommandApplierTests"
    private var defaults: UserDefaults!
    private var store: EventStore!
    /// 2026-03-10 10:07:30 UTC — deliberately off the 15-minute grid.
    private let now = Date(timeIntervalSince1970: 1_773_137_250)

    override func setUp() {
        super.setUp()
        let location = TestStorage.reset(suiteName)
        defaults = UserDefaults(suiteName: suiteName)!
        store = EventStore(defaults: defaults, storage: location, seedsSampleDataIfEmpty: false)
    }

    override func tearDown() {
        store = nil
        defaults = nil
        TestStorage.tearDown(suiteName)
        super.tearDown()
    }

    private func start(eventID: UUID = UUID(), type: String = "Research", start: Date? = nil, end: Date? = nil) -> WristCommand {
        let s = start ?? now
        return WristCommand(id: UUID(), issuedAt: now, kind: .start(eventID: eventID, typeTitle: type, start: s, end: end ?? s.addingTimeInterval(1800)))
    }

    // MARK: Start

    func testStartCreatesOneSingleRangeEventOfTheType() {
        let eventID = UUID()
        let receipt = WristCommandApplier.apply(start(eventID: eventID, type: "  Research "), to: store)
        XCTAssertEqual(receipt.outcome, .applied)
        let created = store.findCalendarEvent(id: eventID)
        XCTAssertEqual(created?.title, "Research")
        XCTAssertEqual(created?.type, "Research")
        XCTAssertEqual(created?.timeRanges, [.init(start: now, end: now.addingTimeInterval(1800))])
        XCTAssertEqual(created?.kind, .event)
        XCTAssertNil(created?.timerStartedAt)
        XCTAssertEqual(store.rawCalendarEvents.count, 1)
    }

    func testStartTwiceWithTheSameEventIDIsADuplicate() {
        let eventID = UUID()
        _ = WristCommandApplier.apply(start(eventID: eventID), to: store)
        let second = WristCommandApplier.apply(start(eventID: eventID, type: "Other"), to: store)
        XCTAssertEqual(second.outcome, .duplicate)
        XCTAssertEqual(store.rawCalendarEvents.count, 1)
        XCTAssertEqual(store.findCalendarEvent(id: eventID)?.type, "Research", "the first start wins")
    }

    func testStartRejectsEmptyTypeAndInvertedRange() {
        XCTAssertEqual(WristCommandApplier.apply(start(type: "   "), to: store).outcome, .rejected)
        XCTAssertEqual(WristCommandApplier.apply(start(start: now, end: now), to: store).outcome, .rejected)
        XCTAssertTrue(store.rawCalendarEvents.isEmpty)
    }

    // MARK: Finish / extend

    func testFinishSnapsToGridAndClampsToFifteenMinutes() {
        let eventID = UUID()
        _ = WristCommandApplier.apply(start(eventID: eventID), to: store)
        // Five minutes in: the clamp wins over the grid.
        let early = WristCommand(id: UUID(), issuedAt: now, kind: .finish(eventID: eventID, at: now.addingTimeInterval(300)))
        XCTAssertEqual(WristCommandApplier.apply(early, to: store).outcome, .applied)
        XCTAssertEqual(store.findCalendarEvent(id: eventID)?.timeRanges.first?.end, now.addingTimeInterval(15 * 60))
        // Fifty-two minutes in: grid-snapped.
        let at = now.addingTimeInterval(52 * 60)
        let late = WristCommand(id: UUID(), issuedAt: now, kind: .finish(eventID: eventID, at: at))
        XCTAssertEqual(WristCommandApplier.apply(late, to: store).outcome, .applied)
        XCTAssertEqual(store.findCalendarEvent(id: eventID)?.timeRanges.first?.end, calendarSnapDateToMinuteGrid(at))
        XCTAssertEqual(WristCommandApplier.adjustedEnd(start: now, requested: at), WristTiming.clampedEnd(start: now, requested: at),
                       "phone rule and the watch's prediction agree")
    }

    func testExtendAddsToTheCurrentEnd() {
        let eventID = UUID()
        _ = WristCommandApplier.apply(start(eventID: eventID), to: store)
        let before = store.findCalendarEvent(id: eventID)!.timeRanges[0].end
        let extend = WristCommand(id: UUID(), issuedAt: now, kind: .extend(eventID: eventID, by: 15 * 60))
        XCTAssertEqual(WristCommandApplier.apply(extend, to: store).outcome, .applied)
        XCTAssertEqual(store.findCalendarEvent(id: eventID)?.timeRanges.first?.end,
                       calendarSnapDateToMinuteGrid(before.addingTimeInterval(15 * 60)))
    }

    func testFinishUnknownEventIsRejected() {
        let receipt = WristCommandApplier.apply(
            WristCommand(id: UUID(), issuedAt: now, kind: .finish(eventID: UUID(), at: now)), to: store)
        XCTAssertEqual(receipt.outcome, .rejected)
        XCTAssertEqual(receipt.reason, "not found")
    }

    func testFinishOnRecurringSeriesIsRefusedUnchanged() {
        var series = Event(title: "Standup", timeRanges: [.init(start: now.addingTimeInterval(-86400 * 3), end: now.addingTimeInterval(-86400 * 3 + 900))], type: "Meeting")
        series.repeatUnit = .day
        store.addCalendarEvent(series)
        let receipt = WristCommandApplier.apply(
            WristCommand(id: UUID(), issuedAt: now, kind: .finish(eventID: series.id, at: now)), to: store)
        XCTAssertEqual(receipt.outcome, .rejected)
        XCTAssertEqual(receipt.reason, "recurring")
        XCTAssertEqual(store.findCalendarEvent(id: series.id)?.timeRanges, series.timeRanges)
    }

    // MARK: Bridge idempotency

    func testBridgeQueuesBeforeAttachAndAppliesOnce() {
        let bridge = WristBridge(ledger: WristAppliedLedger(defaults: defaults))
        let command = start()
        bridge.handle(command)
        XCTAssertEqual(bridge.inboxCountForTesting, 1)
        XCTAssertTrue(store.rawCalendarEvents.isEmpty)

        bridge.attach(store: store, templates: EventTypeTemplateStore(defaults: defaults))
        XCTAssertEqual(bridge.inboxCountForTesting, 0)
        XCTAssertEqual(store.rawCalendarEvents.count, 1)
        XCTAssertEqual(bridge.receiptsForTesting.map(\.outcome), [.applied])

        // The watch retries the same command after a dropped link.
        bridge.handle(command)
        XCTAssertEqual(store.rawCalendarEvents.count, 1)
        XCTAssertEqual(bridge.receiptsForTesting.map(\.outcome), [.applied, .duplicate])
    }

    func testLedgerSurvivesRelaunchAndEvictsOldest() {
        var ledger = WristAppliedLedger(defaults: defaults)
        let first = UUID()
        ledger.insert(first)
        XCTAssertTrue(WristAppliedLedger(defaults: defaults).contains(first), "a fresh instance reads it back")
        for _ in 0..<WristAppliedLedger.capacity { ledger.insert(UUID()) }
        XCTAssertEqual(ledger.count, WristAppliedLedger.capacity)
        XCTAssertFalse(ledger.contains(first), "the oldest id was evicted")
    }

    func testBridgeCapsReceipts() {
        let bridge = WristBridge(ledger: WristAppliedLedger(defaults: defaults))
        bridge.attach(store: store, templates: EventTypeTemplateStore(defaults: defaults))
        for _ in 0..<(WristBridge.receiptLimit + 5) { bridge.handle(start()) }
        XCTAssertEqual(bridge.receiptsForTesting.count, WristBridge.receiptLimit)
        XCTAssertEqual(store.rawCalendarEvents.count, WristBridge.receiptLimit + 5)
    }
}
