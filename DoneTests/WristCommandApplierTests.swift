import XCTest
@testable import Done

/// Wrist commands against a real (isolated) EventStore, and the bridge's
/// idempotency around them.
@MainActor
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
        let early = WristCommand(id: UUID(), issuedAt: now, kind: .finish(eventID: eventID, rangeStart: nil, at: now.addingTimeInterval(300)))
        XCTAssertEqual(WristCommandApplier.apply(early, to: store).outcome, .applied)
        XCTAssertEqual(store.findCalendarEvent(id: eventID)?.timeRanges.first?.end, now.addingTimeInterval(15 * 60))
        // Fifty-two minutes in: grid-snapped.
        let at = now.addingTimeInterval(52 * 60)
        let late = WristCommand(id: UUID(), issuedAt: now, kind: .finish(eventID: eventID, rangeStart: nil, at: at))
        XCTAssertEqual(WristCommandApplier.apply(late, to: store).outcome, .applied)
        XCTAssertEqual(store.findCalendarEvent(id: eventID)?.timeRanges.first?.end, calendarSnapDateToMinuteGrid(at))
        XCTAssertEqual(WristCommandApplier.adjustedEnd(start: now, requested: at), WristTiming.clampedEnd(start: now, requested: at),
                       "phone rule and the watch's prediction agree")
    }

    func testExtendAddsToTheCurrentEnd() {
        let eventID = UUID()
        _ = WristCommandApplier.apply(start(eventID: eventID), to: store)
        let before = store.findCalendarEvent(id: eventID)!.timeRanges[0].end
        let extend = WristCommand(id: UUID(), issuedAt: now, kind: .extend(eventID: eventID, rangeStart: nil, by: 15 * 60))
        XCTAssertEqual(WristCommandApplier.apply(extend, to: store).outcome, .applied)
        XCTAssertEqual(store.findCalendarEvent(id: eventID)?.timeRanges.first?.end,
                       calendarSnapDateToMinuteGrid(before.addingTimeInterval(15 * 60)))
    }

    func testFinishUnknownEventIsRejected() {
        let receipt = WristCommandApplier.apply(
            WristCommand(id: UUID(), issuedAt: now, kind: .finish(eventID: UUID(), rangeStart: nil, at: now)), to: store)
        XCTAssertEqual(receipt.outcome, .rejected)
        XCTAssertEqual(receipt.reason, "not found")
    }

    func testFinishOnRecurringSeriesIsRefusedUnchanged() {
        var series = Event(title: "Standup", timeRanges: [.init(start: now.addingTimeInterval(-86400 * 3), end: now.addingTimeInterval(-86400 * 3 + 900))], type: "Meeting")
        series.repeatUnit = .day
        store.addCalendarEvent(series)
        let receipt = WristCommandApplier.apply(
            WristCommand(id: UUID(), issuedAt: now, kind: .finish(eventID: series.id, rangeStart: nil, at: now)), to: store)
        XCTAssertEqual(receipt.outcome, .rejected)
        XCTAssertEqual(receipt.reason, "recurring")
        XCTAssertEqual(store.findCalendarEvent(id: series.id)?.timeRanges, series.timeRanges)
    }

    func testMultiRangeEditsOnlyTheNamedRange() {
        let eventID = UUID()
        let r0 = Event.TimeRange(start: now.addingTimeInterval(-6 * 3600), end: now.addingTimeInterval(-5 * 3600))
        let r1 = Event.TimeRange(start: now.addingTimeInterval(-20 * 60), end: now.addingTimeInterval(40 * 60))
        store.addCalendarEvent(Event(id: eventID, title: "Split", timeRanges: [r0, r1], type: "Work"))

        let finish = WristCommand(id: UUID(), issuedAt: now, kind: .finish(eventID: eventID, rangeStart: r1.start, at: now))
        XCTAssertEqual(WristCommandApplier.apply(finish, to: store).outcome, .applied)
        let stored = store.findCalendarEvent(id: eventID)!.timeRanges
        XCTAssertEqual(stored[0], r0, "range 0 untouched")
        XCTAssertEqual(stored[1].end, WristCommandApplier.adjustedEnd(start: r1.start, requested: now))

        let unnamed = WristCommand(id: UUID(), issuedAt: now, kind: .extend(eventID: eventID, rangeStart: nil, by: 900))
        let receipt = WristCommandApplier.apply(unnamed, to: store)
        XCTAssertEqual(receipt.outcome, .rejected)
        XCTAssertEqual(receipt.reason, "range not found")
        XCTAssertEqual(store.findCalendarEvent(id: eventID)!.timeRanges, stored, "a guess is refused, nothing changes")

        let wrongStart = WristCommand(id: UUID(), issuedAt: now, kind: .extend(eventID: eventID, rangeStart: now, by: 900))
        XCTAssertEqual(WristCommandApplier.apply(wrongStart, to: store).reason, "range not found")
    }

    /// Range starts written by the phone can carry fractional seconds; the
    /// watch's copy came back through JSON a few nanoseconds off.
    func testNamedRangeMatchesAFractionalStartAfterTheWireRoundTrip() throws {
        let eventID = UUID()
        let fractional = now.addingTimeInterval(-20 * 60 + 0.3982712)
        let r0 = Event.TimeRange(start: now.addingTimeInterval(-6 * 3600), end: now.addingTimeInterval(-5 * 3600))
        let r1 = Event.TimeRange(start: fractional, end: now.addingTimeInterval(40 * 60))
        store.addCalendarEvent(Event(id: eventID, title: "Split", timeRanges: [r0, r1], type: "Work"))
        let wire = try WristWire.decode(Date.self, from: try WristWire.encode(fractional))
        let finish = WristCommand(id: UUID(), issuedAt: now, kind: .finish(eventID: eventID, rangeStart: wire, at: now))
        let roundTripped = try WristWire.decode(WristCommand.self, from: try WristWire.encode(finish))
        XCTAssertEqual(WristCommandApplier.apply(roundTripped, to: store).outcome, .applied)
        let stored = store.findCalendarEvent(id: eventID)!.timeRanges
        XCTAssertEqual(stored[0], r0)
        XCTAssertEqual(stored[1].end, WristCommandApplier.adjustedEnd(start: fractional, requested: now))
    }

    func testRunningTimerIsRefused() {
        let started = now.addingTimeInterval(-600)
        let timer = Event(title: "Reading", timeRanges: [.init(start: started, end: started)], type: "Read", timerStartedAt: started)
        store.addCalendarEvent(timer)
        let receipt = WristCommandApplier.apply(
            WristCommand(id: UUID(), issuedAt: now, kind: .finish(eventID: timer.id, rangeStart: started, at: now)), to: store)
        XCTAssertEqual(receipt.outcome, .rejected)
        XCTAssertEqual(receipt.reason, "timer")
        XCTAssertEqual(store.findCalendarEvent(id: timer.id)?.timeRanges, timer.timeRanges)
    }

    // MARK: Bridge idempotency

    /// A finish that outruns its start is refused but not remembered, so the
    /// durable copy delivered after the start still applies.
    func testFinishBeforeStartAppliesWhenRedelivered() {
        let bridge = WristBridge(ledger: WristAppliedLedger(defaults: defaults), defaults: defaults)
        bridge.attach(store: store, templates: EventTypeTemplateStore(defaults: defaults))
        let eventID = UUID()
        let startCommand = start(eventID: eventID)
        let finish = WristCommand(id: UUID(), issuedAt: now, kind: .finish(eventID: eventID, rangeStart: now, at: now.addingTimeInterval(180)))
        XCTAssertEqual(bridge.handle(finish)?.reason, "not found")
        XCTAssertEqual(bridge.handle(startCommand)?.outcome, .applied)
        XCTAssertEqual(bridge.handle(finish)?.outcome, .applied, "same command id, applied once the start exists")
        XCTAssertEqual(store.findCalendarEvent(id: eventID)?.timeRanges.first?.end, now.addingTimeInterval(15 * 60))
        XCTAssertEqual(bridge.handle(finish)?.outcome, .duplicate, "and remembered from then on")
    }

    /// A command that arrives before the stores exist survives the process:
    /// a new bridge over the same defaults applies it on attach.
    /// The process that applied a command is gone; the snapshot the next
    /// process pushes still carries that command's receipt.
    func testReceiptsSurviveTheProcessThatAppliedThem() {
        let transport = FakeTransport()
        let templates = EventTypeTemplateStore(defaults: defaults)
        let fixedNow = now
        let first = WristBridge(ledger: WristAppliedLedger(defaults: defaults), defaults: defaults, transport: transport)
        first.now = { fixedNow }
        first.attach(store: store, templates: templates)
        let command = start()
        XCTAssertEqual(first.handle(command)?.outcome, .applied)

        let second = WristBridge(ledger: WristAppliedLedger(defaults: defaults), defaults: defaults, transport: transport)
        second.now = { fixedNow }
        second.attach(store: store, templates: templates)
        XCTAssertEqual(transport.pushed.last?.receipts.map(\.id), [command.id])
        XCTAssertEqual(second.handle(command)?.outcome, .duplicate, "and the ledger still knows it")
    }

    /// The phone→watch stats wiring: when the widget's payload lands, the
    /// bridge pushes it, and the watch reads today's hours from it.
    func testStatsLandingOnThePhoneArePushedToTheWatch() async throws {
        let transport = FakeTransport()
        let templates = EventTypeTemplateStore(defaults: defaults)
        let bridge = WristBridge(ledger: WristAppliedLedger(defaults: defaults), defaults: defaults, transport: transport)
        bridge.attach(store: store, templates: templates)
        let start = Calendar.current.startOfDay(for: Date()).addingTimeInterval(60)
        store.addCalendarEvent(Event(title: "Deep work", timeRanges: [.init(start: start, end: start.addingTimeInterval(3600))], type: "Work"))
        store.flushWidgetSnapshotSync()
        await store.awaitDeferredWidgetSync()
        XCTAssertNotNil(store.latestCategoryStats, "the widget payload landed")
        try await Task.sleep(nanoseconds: 900_000_000)
        let pushed = try XCTUnwrap(transport.pushed.last?.stats, "the push after landing carries the stats")
        let hours = CategoryStats.summary(of: pushed, period: .today, asOf: Date()).categories.first { $0.name == "Work" }?.hours
        XCTAssertEqual(try XCTUnwrap(hours), min(1, Date().timeIntervalSince(start) / 3600), accuracy: 0.02)
    }

    func testInboxSurvivesALaunchWithoutAScene() {
        let first = WristBridge(ledger: WristAppliedLedger(defaults: defaults), defaults: defaults)
        let command = start()
        XCTAssertNil(first.handle(command))
        XCTAssertEqual(first.inboxCountForTesting, 1)

        let second = WristBridge(ledger: WristAppliedLedger(defaults: defaults), defaults: defaults)
        XCTAssertEqual(second.inboxCountForTesting, 1, "read back from disk")
        second.attach(store: store, templates: EventTypeTemplateStore(defaults: defaults))
        XCTAssertEqual(second.inboxCountForTesting, 0)
        XCTAssertEqual(store.rawCalendarEvents.count, 1)
        XCTAssertEqual(first.inboxCountForTesting, 0, "one shared queue, drained once")
    }

    private final class FakeTransport: WristSessionTransport {
        var isReadyForSnapshot = true
        var pushed: [WristSnapshot] = []
        func push(context: [String: Any]) throws {
            pushed.append(try WristWire.decode(WristSnapshot.self, from: context[WristWire.snapshotKey] as! Data))
        }
    }

    func testSnapshotIsPushedOnAttachAndOnlyWhenContentChanges() {
        let transport = FakeTransport()
        let bridge = WristBridge(ledger: WristAppliedLedger(defaults: defaults), defaults: defaults, transport: transport)
        // The bridge holds the stores weakly (the app owns them); the test
        // must keep this one alive. And the bridge's clock must sit in the
        // fixture's day for the started event to fall inside the window.
        let templates = EventTypeTemplateStore(defaults: defaults)
        let fixedNow = now
        bridge.now = { fixedNow }
        bridge.attach(store: store, templates: templates)
        XCTAssertEqual(transport.pushed.count, 1, "attach pushes once")
        bridge.pushSnapshot()
        bridge.pushSnapshot()
        XCTAssertEqual(transport.pushed.count, 1, "same content is not re-sent")

        let eventID = UUID()
        bridge.handle(start(eventID: eventID))
        XCTAssertEqual(transport.pushed.count, 2, "a handled command pushes at once, with its receipt")
        XCTAssertEqual(transport.pushed[1].receipts.map(\.outcome), [.applied])
        XCTAssertTrue(transport.pushed[1].occurrences.contains { $0.eventID == eventID })

        // A store change made on the phone itself reaches the watch after the
        // debounce — and exactly once.
        let settled = expectation(description: "debounced push")
        store.updateCalendarEvent({ var e = store.findCalendarEvent(id: eventID)!; e.title = "Renamed"; return e }())
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { settled.fulfill() }
        wait(for: [settled], timeout: 3)
        XCTAssertEqual(transport.pushed.count, 3)
        XCTAssertEqual(transport.pushed[2].occurrences.first { $0.eventID == eventID }?.title, "Renamed")

        transport.isReadyForSnapshot = false
        bridge.handle(start())
        XCTAssertEqual(transport.pushed.count, 3, "no watch, no push")
    }


    func testBridgeQueuesBeforeAttachAndAppliesOnce() {
        let bridge = WristBridge(ledger: WristAppliedLedger(defaults: defaults), defaults: defaults)
        let command = start()
        XCTAssertNil(bridge.handle(command), "nothing to answer before the store exists")
        XCTAssertEqual(bridge.inboxCountForTesting, 1)
        XCTAssertTrue(store.rawCalendarEvents.isEmpty)

        bridge.attach(store: store, templates: EventTypeTemplateStore(defaults: defaults))
        XCTAssertEqual(bridge.inboxCountForTesting, 0)
        XCTAssertEqual(store.rawCalendarEvents.count, 1)
        XCTAssertEqual(bridge.receiptsForTesting.map(\.outcome), [.applied])

        // The watch retries the same command after a dropped link: answered
        // duplicate, and the snapshot keeps carrying the one receipt per id.
        XCTAssertEqual(bridge.handle(command)?.outcome, .duplicate)
        XCTAssertEqual(store.rawCalendarEvents.count, 1)
        XCTAssertEqual(bridge.receiptsForTesting.map(\.outcome), [.applied])
    }

    func testLedgerSurvivesRelaunchAndEvictsOldest() {
        var ledger = WristAppliedLedger(defaults: defaults)
        let first = UUID()
        ledger.record(WristReceipt(id: first, outcome: .applied, reason: nil))
        let reread = WristAppliedLedger(defaults: defaults)
        XCTAssertTrue(reread.contains(first), "a fresh instance reads it back")
        XCTAssertEqual(reread.recent(32), [WristReceipt(id: first, outcome: .applied, reason: nil)], "with its receipt")
        ledger.record(WristReceipt(id: first, outcome: .duplicate, reason: nil))
        XCTAssertEqual(ledger.recent(32).count, 1, "one receipt per id")
        for _ in 0..<WristAppliedLedger.capacity { ledger.record(WristReceipt(id: UUID(), outcome: .rejected, reason: "recurring")) }
        XCTAssertEqual(ledger.count, WristAppliedLedger.capacity)
        XCTAssertFalse(ledger.contains(first), "the oldest id was evicted")
        XCTAssertEqual(ledger.recent(3).count, 3)
    }

    func testBridgeCapsReceiptsCarriedBySnapshots() {
        let transport = FakeTransport()
        let templates = EventTypeTemplateStore(defaults: defaults)
        let fixedNow = now
        let bridge = WristBridge(ledger: WristAppliedLedger(defaults: defaults), defaults: defaults, transport: transport)
        bridge.now = { fixedNow }
        bridge.attach(store: store, templates: templates)
        var last: WristCommand?
        for _ in 0..<(WristBridge.receiptLimit + 5) {
            last = start()
            bridge.handle(last!)
        }
        XCTAssertEqual(transport.pushed.last?.receipts.count, WristBridge.receiptLimit)
        XCTAssertEqual(transport.pushed.last?.receipts.last?.id, last?.id, "newest last")
        XCTAssertEqual(store.rawCalendarEvents.count, WristBridge.receiptLimit + 5)
    }

    /// A "not found" rejection reaches the watch as a receipt (so its
    /// pending entry settles) without the id being counted as seen.
    func testNotFoundReceiptIsCarriedButNotRemembered() {
        let transport = FakeTransport()
        let templates = EventTypeTemplateStore(defaults: defaults)
        let fixedNow = now
        let bridge = WristBridge(ledger: WristAppliedLedger(defaults: defaults), defaults: defaults, transport: transport)
        bridge.now = { fixedNow }
        bridge.attach(store: store, templates: templates)
        let finish = WristCommand(id: UUID(), issuedAt: now, kind: .finish(eventID: UUID(), rangeStart: now, at: now))
        XCTAssertEqual(bridge.handle(finish)?.reason, "not found")
        XCTAssertEqual(transport.pushed.last?.receipts.map(\.id), [finish.id])
        XCTAssertFalse(WristAppliedLedger(defaults: defaults).contains(finish.id))
    }
}
