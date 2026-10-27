import XCTest
@testable import Done

/// The watch's settings page: the settings edit on the wire both ways
/// (including a phone and a watch from before it), the phone writing it
/// into Settings → Apple Watch, the watch's optimistic overlay, and the
/// watch-only zoom and opening period.
@MainActor
final class WristSettingsCommandTests: XCTestCase {
    private let suiteName = "WristSettingsCommandTests"
    private var defaults: UserDefaults!
    private var store: EventStore!
    /// 2026-03-10 10:07:30 UTC.
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

    private func edit(overlap: WristOverlapRule? = nil, background: Bool? = nil, at issued: Date? = nil) -> WristCommand {
        WristCommand(id: UUID(), issuedAt: issued ?? now, kind: .statsSettings(overlap: overlap, excludesBackground: background))
    }

    // MARK: Wire

    func testTheEditRoundTripsWithEitherFieldOrBoth() throws {
        for command in [edit(overlap: .full), edit(background: true), edit(overlap: .latestStart, background: false)] {
            let decoded = try WristWire.decode(WristCommand.self, from: WristWire.encode(command))
            XCTAssertEqual(decoded, command)
            XCTAssertEqual(decoded.eventID, command.id, "an edit is about no event: it waits behind none")
            XCTAssertNil(decoded.rangeStart)
        }
    }

    /// The `Kind` a phone before the edit decodes with: the three cases
    /// it had, synthesized the same way.
    private struct PhoneBeforeTheEdit: Codable {
        enum Kind: Codable {
            case start(eventID: UUID, typeTitle: String, start: Date, end: Date, title: String? = nil)
            case finish(eventID: UUID, rangeStart: Date?, at: Date)
            case extend(eventID: UUID, rangeStart: Date?, by: TimeInterval)
        }

        var id: UUID
        var issuedAt: Date
        var kind: Kind
    }

    /// Such a phone cannot decode the edit: the bridge's `decodeCommand`
    /// returns nil, so the message gets an empty reply and the transfer is
    /// dropped — nothing reaches the ledger, the inbox or the store. Its
    /// own commands still decode both ways.
    func testAPhoneBeforeTheEditRejectsItWithoutTouchingAnythingElse() throws {
        let data = try WristWire.encode(edit(overlap: .full))
        XCTAssertThrowsError(try WristWire.decode(PhoneBeforeTheEdit.self, from: data))

        let finish = WristCommand(id: UUID(), issuedAt: now, kind: .finish(eventID: UUID(), rangeStart: now, at: now))
        let old = try WristWire.decode(PhoneBeforeTheEdit.self, from: WristWire.encode(finish))
        XCTAssertEqual(try WristWire.decode(WristCommand.self, from: WristWire.encode(old)), finish)
    }

    /// An undecodable entry on the phone's disk queue (as a newer watch's
    /// command would be to an older phone) is skipped; the rest apply.
    func testAnUndecodableQueuedCommandDoesNotWedgeTheInbox() {
        let start = WristCommand(id: UUID(), issuedAt: now, kind: .start(
            eventID: UUID(), typeTitle: "Work", start: now, end: now.addingTimeInterval(1800)
        ))
        let garbage = Data(#"{"id":"x","kind":{"somethingNew":{}}}"#.utf8)
        defaults.set([garbage, try! WristWire.encode(start)], forKey: WristBridge.inboxDefaultsKey)
        let bridge = WristBridge(ledger: WristAppliedLedger(defaults: defaults), defaults: defaults)
        XCTAssertEqual(bridge.inboxCountForTesting, 1)
        bridge.attach(store: store, templates: EventTypeTemplateStore(defaults: defaults))
        XCTAssertEqual(bridge.inboxCountForTesting, 0)
        XCTAssertEqual(store.rawCalendarEvents.count, 1)
    }

    func testTheSnapshotSaysWhetherThePhoneTakesEdits() throws {
        let old = WristSnapshot(generatedAt: now, types: [], occurrences: [], receipts: [])
        let oldData = try WristWire.encode(old)
        XCTAssertFalse(String(decoding: oldData, as: UTF8.self).contains("takesSettingsEdits"),
                       "false writes no key: the bytes of a phone before the field")
        XCTAssertFalse(try WristWire.decode(WristSnapshot.self, from: oldData).takesSettingsEdits)

        var new = old
        new.takesSettingsEdits = true
        XCTAssertTrue(try WristWire.decode(WristSnapshot.self, from: WristWire.encode(new)).takesSettingsEdits)
        XCTAssertFalse(new.hasSameContent(as: old), "turning it on is news to the watch")

        let built = WristSnapshotBuilder.snapshot(
            events: [], templates: [], now: now, calendar: .current, language: nil, receipts: [],
            stats: nil, statsSettings: .standard, colorHex: { _ in "#000000" }
        )
        XCTAssertTrue(built.takesSettingsEdits)
    }

    /// A watch before the field reads the new snapshot as before: the
    /// keyed decode it uses ignores a key it does not know.
    func testAWatchBeforeTheFieldReadsTheNewSnapshot() throws {
        struct WatchBeforeTheField: Decodable {
            var version: Int
            var statsSettings: WristStatsSettings
        }
        var snapshot = WristSnapshot(
            generatedAt: now, types: [], occurrences: [], receipts: [],
            statsSettings: WristStatsSettings(overlap: .full)
        )
        snapshot.takesSettingsEdits = true
        let read = try WristWire.decode(WatchBeforeTheField.self, from: WristWire.encode(snapshot))
        XCTAssertEqual(read.statsSettings.overlap, .full)
    }

    // MARK: Phone

    func testTheEditWritesOnlyItsFieldsIntoTheWatchSettings() {
        let before = WristStatsSettings(overlap: .split, excludedTypes: ["Chores"], excludesBackground: false, defaultPeriod: .sevenDays)
        defaults.set(before.encoded, forKey: AppSettingsKeys.watchStatsSettings)

        XCTAssertEqual(WristCommandApplier.apply(edit(overlap: .latestStart), to: store, defaults: defaults).outcome, .applied)
        var expected = before
        expected.overlap = .latestStart
        XCTAssertEqual(WristStatsSettings.load(from: defaults), expected)

        XCTAssertEqual(WristCommandApplier.apply(edit(background: true, at: now.addingTimeInterval(1)), to: store, defaults: defaults).outcome, .applied)
        expected.excludesBackground = true
        XCTAssertEqual(WristStatsSettings.load(from: defaults), expected, "types and period are the phone's alone")
        XCTAssertTrue(store.rawCalendarEvents.isEmpty)
    }

    /// Two edits that cross on different channels: the later choice stands.
    func testAnEditIssuedBeforeTheLastAppliedIsRefused() {
        XCTAssertEqual(WristCommandApplier.apply(edit(overlap: .full, at: now), to: store, defaults: defaults).outcome, .applied)
        let stale = WristCommandApplier.apply(edit(overlap: .split, at: now.addingTimeInterval(-5)), to: store, defaults: defaults)
        XCTAssertEqual(stale.outcome, .rejected)
        XCTAssertEqual(stale.reason, "superseded")
        XCTAssertEqual(WristStatsSettings.load(from: defaults).overlap, .full)
    }

    func testTheBridgeAppliesTheEditAndPushesItWithTheReceipt() {
        let transport = FakeTransport()
        let templates = EventTypeTemplateStore(defaults: defaults)
        let fixedNow = now
        let bridge = WristBridge(ledger: WristAppliedLedger(defaults: defaults), defaults: defaults, transport: transport)
        bridge.now = { fixedNow }
        bridge.attach(store: store, templates: templates)
        XCTAssertEqual(transport.pushed.last?.statsSettings.overlap, .split)

        let command = edit(overlap: .full)
        XCTAssertEqual(bridge.handle(command)?.outcome, .applied)
        XCTAssertEqual(transport.pushed.last?.statsSettings.overlap, .full)
        XCTAssertEqual(transport.pushed.last?.receipts.map(\.id), [command.id])
        XCTAssertEqual(bridge.handle(command)?.outcome, .duplicate)
    }

    private final class FakeTransport: WristSessionTransport {
        var isReadyForSnapshot = true
        var pushed: [WristSnapshot] = []
        func push(context: [String: Any]) throws {
            pushed.append(try WristWire.decode(WristSnapshot.self, from: context[WristWire.snapshotKey] as! Data))
        }
    }

    // MARK: Watch

    func testPendingEditsOverlayThePhonesSettingsInOrderUntilSettled() {
        let phone = WristStatsSettings(overlap: .split, excludedTypes: ["Chores"], excludesBackground: false, defaultPeriod: .threeDays)
        var snapshot = WristSnapshot(generatedAt: now, types: [], occurrences: [], receipts: [], statsSettings: phone)
        let first = edit(overlap: .full, at: now)
        let second = edit(overlap: .latestStart, background: true, at: now.addingTimeInterval(2))
        // Out of order in the list; issued order decides.
        let pending = [WristPendingCommand(command: second), WristPendingCommand(command: first)]
        let shown = WristStateReducer.statsSettings(snapshot, pending: pending)
        XCTAssertEqual(shown.overlap, .latestStart)
        XCTAssertTrue(shown.excludesBackground)
        XCTAssertEqual(shown.excludedTypes, ["Chores"])
        XCTAssertEqual(shown.defaultPeriod, .threeDays)
        XCTAssertEqual(WristStateReducer.statsSettings(snapshot, pending: []), phone)

        // The phone's snapshot carries both receipts: the overlay goes.
        snapshot.receipts = [first, second].map { WristReceipt(id: $0.id, outcome: .applied, reason: nil) }
        XCTAssertTrue(WristStateReducer.settle(pending, snapshot: snapshot, now: now).isEmpty)
    }

    func testAnEditNeitherWaitsBehindNorHoldsUpAnEventsCommands() {
        let eventID = UUID()
        let start = WristPendingCommand(command: WristCommand(id: UUID(), issuedAt: now, kind: .start(
            eventID: eventID, typeTitle: "Work", start: now, end: now.addingTimeInterval(1800)
        )), sentAt: now)
        let settings = WristPendingCommand(command: edit(overlap: .full, at: now.addingTimeInterval(1)))
        let finish = WristPendingCommand(command: WristCommand(id: UUID(), issuedAt: now.addingTimeInterval(2), kind: .finish(
            eventID: eventID, rangeStart: now, at: now.addingTimeInterval(600)
        )))
        let all = [start, settings, finish]
        XCTAssertEqual(WristStateReducer.channel(for: settings, among: all, reachable: true), .message)
        XCTAssertNil(WristStateReducer.channel(for: finish, among: all, reachable: true), "still behind its start only")

        let snapshot = WristSnapshot(generatedAt: now, types: [], occurrences: [], receipts: [])
        let timeline = WristStateReducer.overlaid(snapshot, pending: all, now: now).occurrences
        XCTAssertEqual(timeline.map(\.eventID), [eventID], "an edit adds nothing to the day")
    }

    func testTheWatchsPeriodWinsWhenPickedElseThePhones() {
        XCTAssertEqual(WristLocalSettings.openingPeriod(watch: "", phone: .sevenDays), .sevenDays)
        XCTAssertEqual(WristLocalSettings.openingPeriod(watch: nil, phone: .threeDays), .threeDays)
        XCTAssertEqual(WristLocalSettings.openingPeriod(watch: "thirtyDays", phone: .today), .thirtyDays)
        XCTAssertEqual(WristLocalSettings.openingPeriod(watch: "today", phone: .sevenDays), .today)
        XCTAssertEqual(WristLocalSettings.openingPeriod(watch: "fortnight", phone: .sevenDays), .sevenDays,
                       "an unknown pick reads as none")
        for period in WristStatsPeriod.allCases {
            XCTAssertEqual(WristLocalSettings.openingPeriod(watch: period.rawValue, phone: .today), period)
        }
    }

    func testZoomMapsToHourHeights() {
        XCTAssertEqual(WristLocalSettings.Zoom.small.hourHeight, 44)
        XCTAssertEqual(WristLocalSettings.Zoom.medium.hourHeight, 64)
        XCTAssertEqual(WristLocalSettings.Zoom.large.hourHeight, 88)
        XCTAssertEqual(WristLocalSettings.Zoom.standard, .medium, "the page as it was")
        XCTAssertEqual(WristLocalSettings.Zoom(stored: nil), .medium)
        XCTAssertEqual(WristLocalSettings.Zoom(stored: "huge"), .medium)
        XCTAssertEqual(WristLocalSettings.Zoom(stored: "large"), .large)
        let heights = WristLocalSettings.Zoom.allCases.map(\.hourHeight)
        XCTAssertEqual(heights, heights.sorted(), "listed smallest first, the order the row cycles")
    }

    /// The drag at every zoom: the same hour of points is the same hour of
    /// the day, and the magnet reaches the same number of points (so fewer
    /// minutes the larger the zoom).
    func testTheDraftMappingHoldsAtEveryZoom() {
        let dayStart = Date(timeIntervalSince1970: 1_773_100_800)
        let dayEnd = dayStart.addingTimeInterval(86_400)
        for zoom in WristLocalSettings.Zoom.allCases {
            let hour = zoom.hourHeight
            let edge = dayStart.addingTimeInterval(13 * 3600 + 7 * 60)
            let m = WristDraftMapping(dayStart: dayStart, dayEnd: dayEnd, height: 24 * hour, edges: [edge])
            let range = m.range(anchorY: 10 * hour, currentY: 11 * hour)
            XCTAssertEqual(range.start, dayStart.addingTimeInterval(10 * 3600), "\(zoom)")
            XCTAssertEqual(range.end, dayStart.addingTimeInterval(11 * 3600), "\(zoom)")
            let upward = m.range(anchorY: 11 * hour, currentY: 10 * hour)
            XCTAssertEqual(upward.start, range.start, "\(zoom)")
            XCTAssertEqual(upward.end, range.end, "\(zoom)")

            let short = m.range(anchorY: 10 * hour, currentY: 10 * hour + 1)
            XCTAssertEqual(short.end.timeIntervalSince(short.start), WristTiming.minimumDuration, "\(zoom)")

            let edgeY = 13 * hour + 7 * hour / 60
            XCTAssertEqual(m.point(atY: edgeY + m.snapPoints - 1).time, edge, "\(zoom): inside the magnet")
            XCTAssertNotEqual(m.point(atY: edgeY + m.snapPoints + 2).time, edge, "\(zoom): past it")
            XCTAssertEqual(m.rawTime(atY: 24 * hour), dayEnd)
        }
    }
}
