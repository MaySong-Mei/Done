import XCTest
@testable import Done

/// Moving and resizing a block on the watch's today page: the drag as data
/// (`WristBlockEdit`) at every zoom, the range rule both sides share
/// (`WristRangeEdit`), the range edit on the wire both ways (including a
/// phone and a watch from before it), the phone applying it, and the
/// watch's optimistic overlay until the phone answers.
@MainActor
final class WristBlockEditTests: XCTestCase {
    private let suiteName = "WristBlockEditTests"
    private var defaults: UserDefaults!
    private var store: EventStore!
    /// 2026-03-10 00:00 UTC.
    private let dayStart = Date(timeIntervalSince1970: 1_773_100_800)
    private var dayEnd: Date { dayStart.addingTimeInterval(86_400) }

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

    private func at(_ hours: Double) -> Date { dayStart.addingTimeInterval(hours * 3600) }

    private func edit(
        _ from: Double, _ to: Double, mode: WristEditMode, pressHour: Double, hourHeight: Double,
        edges: [Date] = []
    ) -> WristBlockEdit {
        let mapping = WristDraftMapping(dayStart: dayStart, dayEnd: dayEnd, height: 24 * hourHeight, edges: edges)
        return WristBlockEdit(
            mapping: mapping, original: WristTimeSpan(start: at(from), end: at(to)),
            mode: mode, anchorY: pressHour * hourHeight
        )
    }

    private var zooms: [Double] { WristLocalSettings.Zoom.allCases.map { Double($0.hourHeight) } }

    // MARK: Drag

    func testAMoveKeepsTheLengthAndStepsByQuarterHoursAtEveryZoom() {
        for hour in zooms {
            let e = edit(10, 11, mode: .move, pressHour: 10.5, hourHeight: hour)
            let moved = e.range(currentY: 11.5 * hour)
            XCTAssertEqual(moved.start, at(11), "\(hour)")
            XCTAssertEqual(moved.end, at(12), "\(hour)")
            XCTAssertEqual(moved.moving.time, moved.start, "the start follows the finger")

            let nudge = e.range(currentY: 10.5 * hour + hour * 7 / 60)
            XCTAssertEqual(nudge.start, at(10), "\(hour): under half a quarter hour stays put")
            let step = e.range(currentY: 10.5 * hour + hour * 8 / 60)
            XCTAssertEqual(step.start, at(10.25), "\(hour): past half a quarter hour takes the step")
            let up = e.range(currentY: 10.5 * hour - 2 * hour)
            XCTAssertEqual(up.start, at(8), "\(hour)")
            XCTAssertEqual(up.end, at(9), "\(hour)")
        }
    }

    /// The phone's drag moves by whole quarter hours, so a block off the
    /// grid keeps its minutes.
    func testAnOffGridBlockKeepsItsMinutes() {
        let e = WristBlockEdit(
            mapping: WristDraftMapping(dayStart: dayStart, dayEnd: dayEnd, height: 24 * 64, edges: []),
            original: WristTimeSpan(start: at(10).addingTimeInterval(7 * 60), end: at(10).addingTimeInterval(52 * 60)),
            mode: .move, anchorY: 10.5 * 64
        )
        let moved = e.range(currentY: 11.5 * 64)
        XCTAssertEqual(moved.start, at(11).addingTimeInterval(7 * 60))
        XCTAssertEqual(moved.end, at(11).addingTimeInterval(52 * 60))
    }

    func testAMovedBlockLandsOnANeighboursEdgeWithinTheMagnet() {
        for hour in zooms {
            let neighbour = at(13).addingTimeInterval(7 * 60)
            let e = edit(10, 11, mode: .move, pressHour: 10.5, hourHeight: hour, edges: [neighbour])
            // Finger moved so the block's end sits just inside the magnet
            // above the neighbour's start.
            let travelToEdge = (neighbour.timeIntervalSince(at(11)) / 3600) * hour
            let inside = e.range(currentY: 10.5 * hour + travelToEdge - 6)
            XCTAssertEqual(inside.end, neighbour, "\(hour)")
            XCTAssertEqual(inside.end.timeIntervalSince(inside.start), 3600, "\(hour): still an hour long")
            XCTAssertEqual(inside.moving.edge, neighbour)
            XCTAssertEqual(inside.moving.time, neighbour, "the edge on the magnet is the one that ticks")
            let outside = e.range(currentY: 10.5 * hour + travelToEdge - 12)
            XCTAssertNotEqual(outside.end, neighbour, "\(hour)")
            XCTAssertNil(outside.moving.edge)
        }
    }

    func testResizingAnEdgeStepsSnapsAndKeepsTheMinimum() {
        for hour in zooms {
            let bottom = edit(10, 11, mode: .resizeBottom, pressHour: 11, hourHeight: hour)
            XCTAssertEqual(bottom.range(currentY: 12.5 * hour).end, at(12.5), "\(hour)")
            XCTAssertEqual(bottom.range(currentY: 12.5 * hour).start, at(10), "\(hour): the other edge holds")
            XCTAssertEqual(bottom.range(currentY: 8 * hour).end, at(10.25), "\(hour): never under the minimum")
            XCTAssertEqual(bottom.range(currentY: 30 * hour).end, dayEnd, "\(hour): never out of the day")

            let top = edit(10, 11, mode: .resizeTop, pressHour: 10, hourHeight: hour)
            XCTAssertEqual(top.range(currentY: 9.25 * hour).start, at(9.25), "\(hour)")
            XCTAssertEqual(top.range(currentY: 9.25 * hour).end, at(11), "\(hour)")
            XCTAssertEqual(top.range(currentY: 13 * hour).start, at(10.75), "\(hour): never under the minimum")
            XCTAssertEqual(top.range(currentY: -5 * hour).start, dayStart, "\(hour): never before midnight")

            let neighbour = at(12).addingTimeInterval(4 * 60)
            let magnet = edit(10, 11, mode: .resizeBottom, pressHour: 11, hourHeight: hour, edges: [neighbour])
            let near = magnet.range(currentY: 11 * hour + (64.0 / 60) * hour - 5)
            XCTAssertEqual(near.end, neighbour, "\(hour)")
            XCTAssertEqual(near.moving.edge, neighbour)
        }
    }

    /// The page shows one day: an edge cannot leave it, and a move never
    /// takes a block further out of it than it already was.
    func testCrossingMidnightClamps() {
        for hour in zooms {
            let late = edit(22, 23.5, mode: .move, pressHour: 22.5, hourHeight: hour)
            let pushed = late.range(currentY: 26 * hour)
            XCTAssertEqual(pushed.end, dayEnd, "\(hour)")
            XCTAssertEqual(pushed.start, at(22.5), "\(hour): the length holds")
            let early = edit(0.5, 1.5, mode: .move, pressHour: 1, hourHeight: hour)
            XCTAssertEqual(early.range(currentY: -3 * hour).start, dayStart, "\(hour)")

            // Sleep from 23:00 yesterday: it can go later, not further back.
            let night = edit(-1, 7, mode: .move, pressHour: 3, hourHeight: hour)
            XCTAssertEqual(night.range(currentY: 1 * hour).start, at(-1), "\(hour)")
            XCTAssertEqual(night.range(currentY: 4 * hour).start, at(0), "\(hour)")
            XCTAssertEqual(night.range(currentY: 4 * hour).end, at(8), "\(hour)")
        }
    }

    /// The edge zone at each zoom: a quarter of the block, at least 12 and
    /// at most 18 points, and none (move only) on a block without room for
    /// a fingertip at both edges and in the middle.
    func testTheEdgeZoneAtEveryZoom() {
        let expectedHour: [Double: Double] = [44: 12, 64: 15.75, 88: 18]
        for hour in zooms {
            let oneHour = hour - 1 // as drawn: a point of gap below each block
            let zone = WristBlockEdit.edgeZone(blockHeight: oneHour)
            XCTAssertEqual(zone, expectedHour[hour], "\(hour)")
            XCTAssertGreaterThanOrEqual(zone, WristBlockEdit.minimumEdgeZone)
            XCTAssertGreaterThanOrEqual(oneHour - 2 * zone, WristBlockEdit.minimumEdgeZone, "\(hour): the middle stays a fingertip")

            func mode(_ y: Double, top: Bool = true, bottom: Bool = true) -> WristEditMode {
                WristBlockEdit.mode(pressY: y, blockHeight: oneHour, canResizeTop: top, canResizeBottom: bottom)
            }
            XCTAssertEqual(mode(zone - 1), .resizeTop, "\(hour)")
            XCTAssertEqual(mode(zone + 1), .move, "\(hour)")
            XCTAssertEqual(mode(oneHour / 2), .move, "\(hour)")
            XCTAssertEqual(mode(oneHour - zone + 1), .resizeBottom, "\(hour)")
            XCTAssertEqual(mode(1, top: false), .move, "\(hour): a clipped edge cannot be grabbed")
            XCTAssertEqual(mode(oneHour - 1, bottom: false), .move, "\(hour)")
        }
        // A half hour: move only at the small zoom, edges from the medium.
        XCTAssertEqual(WristBlockEdit.edgeZone(blockHeight: 22 - 1), 0)
        XCTAssertEqual(WristBlockEdit.mode(pressY: 1, blockHeight: 21, canResizeTop: true, canResizeBottom: true), .move)
        XCTAssertEqual(WristBlockEdit.edgeZone(blockHeight: 32 - 1), 0)
        XCTAssertEqual(WristBlockEdit.edgeZone(blockHeight: 44 - 1), 12)
    }

    /// Whatever the drag shows, the phone keeps: the shared rule leaves
    /// every range the drag can produce as it is.
    func testThePhoneKeepsEveryRangeTheDragShows() {
        let neighbours = [at(13).addingTimeInterval(7 * 60), at(8).addingTimeInterval(52 * 60), at(16)]
        for hour in zooms {
            for mode in [WristEditMode.move, .resizeTop, .resizeBottom] {
                for original in [(10.0, 11.0), (10.0 + 7.0 / 60, 10.0 + 52.0 / 60), (-1.0, 7.0), (22.0, 24.0)] {
                    let press = mode == .resizeTop ? original.0 : mode == .resizeBottom ? original.1 : (original.0 + original.1) / 2
                    let e = edit(original.0, original.1, mode: mode, pressHour: max(0, min(24, press)), hourHeight: hour, edges: neighbours)
                    var y = -2 * hour
                    while y <= 26 * hour {
                        let shown = e.range(currentY: y)
                        let kept = WristRangeEdit.settled(
                            original: e.original, requested: WristTimeSpan(start: shown.start, end: shown.end), edges: neighbours
                        )
                        XCTAssertEqual(kept, WristTimeSpan(start: shown.start, end: shown.end), "\(hour) \(mode) \(original) y=\(y)")
                        XCTAssertGreaterThanOrEqual(shown.end.timeIntervalSince(shown.start), WristTiming.minimumDuration)
                        y += 1.5
                    }
                }
            }
        }
    }

    // MARK: Range rule

    func testTheRangeRule() {
        let original = WristTimeSpan(start: at(10), end: at(11))
        func settled(_ start: Date, _ end: Date, edges: [Date] = []) -> WristTimeSpan? {
            WristRangeEdit.settled(original: original, requested: WristTimeSpan(start: start, end: end), edges: edges)
        }
        XCTAssertEqual(settled(at(11), at(12)), WristTimeSpan(start: at(11), end: at(12)))
        XCTAssertEqual(settled(at(10).addingTimeInterval(400), at(11)), WristTimeSpan(start: at(10), end: at(11)),
                       "off the grid and no neighbour there: to the nearest mark")
        let edge = at(12).addingTimeInterval(400)
        XCTAssertEqual(settled(at(10), edge, edges: [edge]), WristTimeSpan(start: at(10), end: edge), "a neighbour's edge holds")
        XCTAssertEqual(settled(at(10.75).addingTimeInterval(300), at(11)), WristTimeSpan(start: at(10.75), end: at(11)))
        XCTAssertEqual(settled(at(10.9), at(11)), WristTimeSpan(start: at(10.75), end: at(11)),
                       "too short from the top: the start gives way, the end holds")
        XCTAssertEqual(settled(at(10), at(10.1)), WristTimeSpan(start: at(10), end: at(10.25)),
                       "too short from the bottom: the end gives way")
        XCTAssertNil(settled(at(11), at(10)))
        XCTAssertNil(settled(at(11), at(11)))

        let offGrid = WristTimeSpan(start: at(10).addingTimeInterval(7 * 60), end: at(11).addingTimeInterval(7 * 60))
        let stepped = WristRangeEdit.settled(
            original: offGrid,
            requested: WristTimeSpan(start: offGrid.start.addingTimeInterval(1800), end: offGrid.end.addingTimeInterval(1800)),
            edges: []
        )
        XCTAssertEqual(stepped, WristTimeSpan(start: offGrid.start.addingTimeInterval(1800), end: offGrid.end.addingTimeInterval(1800)),
                       "whole quarter hours from an off-grid edge keep its minutes")
    }

    // MARK: Wire

    private func setRange(_ eventID: UUID, rangeStart: Date?, _ start: Date, _ end: Date, issued: Date? = nil) -> WristCommand {
        WristCommand(id: UUID(), issuedAt: issued ?? at(12), kind: .setRange(eventID: eventID, rangeStart: rangeStart, start: start, end: end))
    }

    func testTheEditRoundTrips() throws {
        let eventID = UUID()
        let command = setRange(eventID, rangeStart: at(10), at(11), at(12))
        let decoded = try WristWire.decode(WristCommand.self, from: WristWire.encode(command))
        XCTAssertEqual(decoded, command)
        XCTAssertEqual(decoded.eventID, eventID, "it waits behind, and holds up, its event's commands")
        XCTAssertEqual(decoded.rangeStart, at(10))
        XCTAssertNil(try WristWire.decode(WristCommand.self, from: WristWire.encode(setRange(eventID, rangeStart: nil, at(1), at(2)))).rangeStart)
    }

    /// The `Kind` a phone before the edit decodes with: the four cases it
    /// had, synthesized the same way.
    private struct PhoneBeforeTheEdit: Codable {
        enum Kind: Codable {
            case start(eventID: UUID, typeTitle: String, start: Date, end: Date, title: String? = nil)
            case finish(eventID: UUID, rangeStart: Date?, at: Date)
            case extend(eventID: UUID, rangeStart: Date?, by: TimeInterval)
            case statsSettings(overlap: WristOverlapRule? = nil, excludesBackground: Bool? = nil)
        }

        var id: UUID
        var issuedAt: Date
        var kind: Kind
    }

    /// Such a phone cannot decode the edit, so its bridge drops it (empty
    /// reply, transfer discarded); its own commands still decode both ways.
    func testAPhoneBeforeTheEditCannotDecodeIt() throws {
        XCTAssertThrowsError(try WristWire.decode(PhoneBeforeTheEdit.self, from: WristWire.encode(setRange(UUID(), rangeStart: at(10), at(11), at(12)))))
        let extend = WristCommand(id: UUID(), issuedAt: at(12), kind: .extend(eventID: UUID(), rangeStart: at(10), by: 900))
        let old = try WristWire.decode(PhoneBeforeTheEdit.self, from: WristWire.encode(extend))
        XCTAssertEqual(try WristWire.decode(WristCommand.self, from: WristWire.encode(old)), extend)
    }

    /// An edit queued on the phone's disk that it cannot read (a newer
    /// watch's kind, to an older phone) is skipped; the rest apply.
    func testAnUnreadableQueuedEditDoesNotWedgeTheInbox() throws {
        let start = WristCommand(id: UUID(), issuedAt: at(12), kind: .start(
            eventID: UUID(), typeTitle: "Work", start: at(9), end: at(10)
        ))
        var unknown = String(decoding: try WristWire.encode(setRange(UUID(), rangeStart: at(9), at(10), at(11))), as: UTF8.self)
        unknown = unknown.replacingOccurrences(of: "\"setRange\"", with: "\"someLaterKind\"")
        defaults.set([Data(unknown.utf8), try WristWire.encode(start)], forKey: WristBridge.inboxDefaultsKey)
        let bridge = WristBridge(ledger: WristAppliedLedger(defaults: defaults), defaults: defaults)
        XCTAssertEqual(bridge.inboxCountForTesting, 1)
        bridge.attach(store: store, templates: EventTypeTemplateStore(defaults: defaults))
        XCTAssertEqual(bridge.inboxCountForTesting, 0)
        XCTAssertEqual(store.rawCalendarEvents.count, 1)
    }

    /// The watch offers the drag only when the phone says it takes edits:
    /// false writes no key, an old snapshot reads false, and a watch from
    /// before the field reads the new snapshot as before.
    func testTheSnapshotSaysWhetherThePhoneTakesRangeEdits() throws {
        let old = WristSnapshot(generatedAt: at(12), types: [], occurrences: [], receipts: [])
        let oldData = try WristWire.encode(old)
        XCTAssertFalse(String(decoding: oldData, as: UTF8.self).contains("takesRangeEdits"))
        XCTAssertFalse(try WristWire.decode(WristSnapshot.self, from: oldData).takesRangeEdits)

        var new = old
        new.takesRangeEdits = true
        XCTAssertTrue(try WristWire.decode(WristSnapshot.self, from: WristWire.encode(new)).takesRangeEdits)
        XCTAssertFalse(new.hasSameContent(as: old), "turning it on is news to the watch")

        struct WatchBeforeTheField: Decodable {
            var version: Int
            var takesSettingsEdits: Bool?
        }
        new.takesSettingsEdits = true
        XCTAssertEqual(try WristWire.decode(WatchBeforeTheField.self, from: WristWire.encode(new)).takesSettingsEdits, true)

        let built = WristSnapshotBuilder.snapshot(
            events: [], templates: [], now: at(12), calendar: .current, language: nil, receipts: [],
            colorHex: { _ in "#000000" }
        )
        XCTAssertTrue(built.takesRangeEdits)
    }

    // MARK: Phone

    private func addEvent(_ title: String, _ ranges: [(Double, Double)], configure: (inout Event) -> Void = { _ in }) -> Event {
        var event = Event(title: title, timeRanges: ranges.map { .init(start: at($0.0), end: at($0.1)) }, type: "Work")
        configure(&event)
        store.addCalendarEvent(event)
        return event
    }

    private func apply(_ command: WristCommand) -> WristReceipt {
        WristCommandApplier.apply(command, to: store, defaults: defaults)
    }

    func testThePhoneMovesAndResizesTheRange() {
        let event = addEvent("Block", [(10, 11)])
        XCTAssertEqual(apply(setRange(event.id, rangeStart: at(10), at(11), at(12))).outcome, .applied)
        XCTAssertEqual(store.findCalendarEvent(id: event.id)?.timeRanges, [.init(start: at(11), end: at(12))])
        XCTAssertEqual(apply(setRange(event.id, rangeStart: at(11), at(11), at(13.5))).outcome, .applied)
        XCTAssertEqual(store.findCalendarEvent(id: event.id)?.timeRanges, [.init(start: at(11), end: at(13.5))])
        XCTAssertEqual(apply(setRange(event.id, rangeStart: nil, at(9).addingTimeInterval(200), at(13.5))).outcome, .applied,
                       "the only range needs no name")
        XCTAssertEqual(store.findCalendarEvent(id: event.id)?.timeRanges, [.init(start: at(9), end: at(13.5))],
                       "an edge off the grid and on no neighbour goes to the grid")
    }

    func testThePhoneKeepsANeighboursEdgeAndTheMinimum() {
        _ = addEvent("Neighbour", [(12 + 7.0 / 60, 13)])
        let event = addEvent("Block", [(10, 11)])
        let edge = at(12 + 7.0 / 60)
        let start = at(11).addingTimeInterval(7 * 60)
        XCTAssertEqual(apply(setRange(event.id, rangeStart: at(10), start, edge)).outcome, .applied)
        XCTAssertEqual(store.findCalendarEvent(id: event.id)?.timeRanges, [.init(start: start, end: edge)],
                       "moved onto the neighbour by its end: the length holds, so the start keeps its minutes")
        XCTAssertEqual(apply(setRange(event.id, rangeStart: start, start, at(12) + 40 * 60)).outcome, .applied)
        XCTAssertEqual(store.findCalendarEvent(id: event.id)?.timeRanges, [.init(start: start, end: at(12.75))],
                       "a resized end on nothing goes to the grid")
        XCTAssertEqual(apply(setRange(event.id, rangeStart: start, start, start.addingTimeInterval(300))).outcome, .applied)
        XCTAssertEqual(store.findCalendarEvent(id: event.id)?.timeRanges, [.init(start: start, end: start.addingTimeInterval(900))],
                       "never under the minimum")
        let receipt = apply(setRange(event.id, rangeStart: start, start, start.addingTimeInterval(900)))
        XCTAssertEqual(receipt.outcome, .applied, "the range it already has: applied, nothing written")
    }

    func testThePhoneRefusesWhatItsQuickActionsRefuse() {
        let series = addEvent("Standup", [(9, 9.25)]) { $0.repeatUnit = .day }
        let timer = addEvent("Reading", [(8, 8)]) { $0.timerStartedAt = self.at(8) }
        let allDay = addEvent("Holiday", [(0, 24)]) { $0.isAllDay = true }
        let split = addEvent("Split", [(6, 7), (10, 11)])
        let cases: [(WristCommand, String)] = [
            (setRange(series.id, rangeStart: at(9), at(10), at(10.25)), "recurring"),
            (setRange(timer.id, rangeStart: at(8), at(9), at(10)), "timer"),
            (setRange(allDay.id, rangeStart: at(0), at(1), at(2)), "all day"),
            (setRange(split.id, rangeStart: nil, at(12), at(13)), "range not found"),
            (setRange(split.id, rangeStart: at(8), at(12), at(13)), "range not found"),
            (setRange(UUID(), rangeStart: at(8), at(12), at(13)), "not found"),
            (setRange(split.id, rangeStart: at(10), at(13), at(12)), "invalid range"),
        ]
        let before = store.rawCalendarEvents
        for (command, reason) in cases {
            let receipt = apply(command)
            XCTAssertEqual(receipt.outcome, .rejected, reason)
            XCTAssertEqual(receipt.reason, reason)
        }
        XCTAssertEqual(store.rawCalendarEvents, before, "nothing changed")
    }

    func testAMultiRangeEventEditsOnlyTheNamedRangeAndStaysInOrder() {
        let split = addEvent("Split", [(6, 7), (10, 11)])
        XCTAssertEqual(apply(setRange(split.id, rangeStart: at(10), at(4), at(5))).outcome, .applied)
        XCTAssertEqual(store.findCalendarEvent(id: split.id)?.timeRanges, [
            .init(start: at(4), end: at(5)), .init(start: at(6), end: at(7)),
        ])
    }

    func testTheBridgeAppliesTheEditAndPushesItWithTheReceipt() {
        let transport = FakeTransport()
        let fixedNow = at(12)
        let bridge = WristBridge(ledger: WristAppliedLedger(defaults: defaults), defaults: defaults, transport: transport)
        bridge.now = { fixedNow }
        // The bridge holds the stores weakly.
        let templates = EventTypeTemplateStore(defaults: defaults)
        bridge.attach(store: store, templates: templates)
        XCTAssertEqual(transport.pushed.last?.takesRangeEdits, true)
        let event = addEvent("Block", [(10, 11)])
        let command = setRange(event.id, rangeStart: at(10), at(14), at(15))
        XCTAssertEqual(bridge.handle(command)?.outcome, .applied)
        let pushed = transport.pushed.last
        XCTAssertEqual(pushed?.receipts.map(\.id), [command.id])
        XCTAssertEqual(pushed?.occurrences.first { $0.eventID == event.id }.map { [$0.start, $0.end] }, [at(14), at(15)])
        XCTAssertEqual(bridge.handle(command)?.outcome, .duplicate)
        XCTAssertEqual(store.findCalendarEvent(id: event.id)?.timeRanges, [.init(start: at(14), end: at(15))])
    }

    private final class FakeTransport: WristSessionTransport {
        var isReadyForSnapshot = true
        var pushed: [WristSnapshot] = []
        func push(context: [String: Any]) throws {
            pushed.append(try WristWire.decode(WristSnapshot.self, from: context[WristWire.snapshotKey] as! Data))
        }
    }

    // MARK: Watch

    private func occurrence(_ eventID: UUID, _ from: Double, _ to: Double) -> WristOccurrence {
        WristOccurrence(
            id: "\(eventID)-\(from)", eventID: eventID, title: "Block", type: "Work", colorHex: "#0A84FF",
            start: at(from), end: at(to), isInterrupt: false, quickActionsEnabled: true
        )
    }

    func testThePendingEditShowsAtOnceAndLeavesWhenTheSnapshotReflectsIt() {
        let eventID = UUID(), other = UUID()
        var snapshot = WristSnapshot(
            generatedAt: at(12), types: [], occurrences: [occurrence(eventID, 10, 11), occurrence(other, 13, 14)], receipts: []
        )
        let command = setRange(eventID, rangeStart: at(10), at(12), at(13))
        let pending = [WristPendingCommand(command: command, sentAt: at(12))]
        let (shown, pendingIDs) = WristStateReducer.overlaid(snapshot, pending: pending, now: at(12))
        XCTAssertEqual(shown.first { $0.eventID == eventID }.map { [$0.start, $0.end] }, [at(12), at(13)])
        XCTAssertEqual(shown.first { $0.eventID == other }?.start, at(13), "only the named block moves")
        XCTAssertEqual(pendingIDs, [eventID])

        snapshot.occurrences[0].start = at(12)
        snapshot.occurrences[0].end = at(13)
        snapshot.receipts = [WristReceipt(id: command.id, outcome: .applied, reason: nil)]
        XCTAssertTrue(WristStateReducer.settle(pending, snapshot: snapshot, now: at(12)).isEmpty)
    }

    func testARefusedEditPutsTheBlockBack() {
        let eventID = UUID()
        let snapshot = WristSnapshot(generatedAt: at(12), types: [], occurrences: [occurrence(eventID, 10, 11)], receipts: [])
        let command = setRange(eventID, rangeStart: at(10), at(12), at(13))
        var pending = [WristPendingCommand(command: command, sentAt: at(12))]
        pending = WristStateReducer.acknowledge(
            pending, receipt: WristReceipt(id: command.id, outcome: .rejected, reason: "recurring"), repliedAt: at(12), now: at(12)
        )
        XCTAssertTrue(pending.isEmpty)
        XCTAssertEqual(WristStateReducer.overlaid(snapshot, pending: pending, now: at(12)).occurrences.first?.start, at(10))

        // Refused by a receipt in the snapshot (the transfer path): gone too.
        var refused = snapshot
        refused.receipts = [WristReceipt(id: command.id, outcome: .rejected, reason: "recurring")]
        XCTAssertTrue(WristStateReducer.settle([WristPendingCommand(command: command, sentAt: at(12))], snapshot: refused, now: at(12)).isEmpty)
    }

    /// Edits chain: each later command names the range where the one before
    /// put it, and the overlay follows them in order. An edit naming a range
    /// that is not there changes nothing — it never lands on another range.
    func testEditsChainInOrderAndAMissingRangeChangesNothing() {
        let eventID = UUID()
        let snapshot = WristSnapshot(generatedAt: at(12), types: [], occurrences: [occurrence(eventID, 10, 11), occurrence(eventID, 15, 16)], receipts: [])
        let first = setRange(eventID, rangeStart: at(10), at(11), at(12), issued: at(12))
        let second = WristCommand(id: UUID(), issuedAt: at(12).addingTimeInterval(1), kind: .extend(eventID: eventID, rangeStart: at(11), by: 900))
        let stray = setRange(eventID, rangeStart: at(9), at(20), at(21), issued: at(12).addingTimeInterval(2))
        let shown = WristStateReducer.overlaid(
            snapshot, pending: [first, second, stray].map { WristPendingCommand(command: $0) }, now: at(12)
        ).occurrences
        XCTAssertEqual(shown.map { [$0.start, $0.end] }, [[at(11), at(12.25)], [at(15), at(16)]])

        let finish = WristPendingCommand(command: WristCommand(
            id: UUID(), issuedAt: at(13), kind: .finish(eventID: eventID, rangeStart: at(11), at: at(13))
        ))
        XCTAssertNil(WristStateReducer.channel(for: finish, among: [WristPendingCommand(command: first, sentAt: at(12)), finish], reachable: true),
                     "a later command waits for the edit's answer")
    }
}
