//
//  AwaitingNameTests.swift
//  DoneTests
//
//  "Name later" from the watch, end to end on the phone side:
//    1. Wire: the start's `awaitsName` is optional both ways — a phone
//       before it decodes the start and stores the type-titled event, and a
//       start from a watch before it decodes here unmarked; the snapshot's
//       `awaitsName` is left out when false.
//    2. The applier marks only a "name later" start, under the title it
//       stored; the watch's own overlay draws its pending block waiting.
//    3. A mark asks only while the title is unchanged, the event exists and
//       it is younger than its lifetime; the prompt's answers end it.
//    4. The day timeline draws the ring and badge on all three paths —
//       full render, cheap vertical repaint, viewport cull — and drops them
//       when the mark goes or the event is renamed. Each path's paint is
//       counted, so a pass that never ran cannot pass.
//

import XCTest
import UIKit
@testable import Done

@MainActor
final class AwaitingNameTests: XCTestCase {
    private let suiteName = "AwaitingNameTests"
    private var defaults: UserDefaults!
    private var store: EventStore!
    private var marks: AwaitingNameStore!
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        super.setUp()
        let location = TestStorage.reset(suiteName)
        defaults = UserDefaults(suiteName: suiteName)!
        store = EventStore(defaults: defaults, storage: location, seedsSampleDataIfEmpty: false)
        clock = t0
        marks = AwaitingNameStore(defaults: defaults, now: { [unowned self] in self.clock })
    }

    override func tearDown() {
        marks = nil
        store = nil
        defaults = nil
        TestStorage.tearDown(suiteName)
        super.tearDown()
    }

    private func start(_ eventID: UUID = UUID(), title: String? = nil, awaitsName: Bool? = nil) -> WristCommand {
        WristCommand(id: UUID(), issuedAt: t0, kind: .start(
            eventID: eventID, typeTitle: "Work", start: t0, end: t0 + 1800, title: title, awaitsName: awaitsName
        ))
    }

    // MARK: Wire

    /// The command's shape before `awaitsName` (with the title), as the
    /// phone in the field decodes it.
    private struct PreviousCommand: Codable, Equatable {
        enum Kind: Codable, Equatable {
            case start(eventID: UUID, typeTitle: String, start: Date, end: Date, title: String? = nil)
            case finish(eventID: UUID, rangeStart: Date?, at: Date)
            case extend(eventID: UUID, rangeStart: Date?, by: TimeInterval)
        }

        var id: UUID
        var issuedAt: Date
        var kind: Kind
    }

    func testAPhoneBeforeTheFieldDecodesANameLaterStartAsAPlainOne() throws {
        let eventID = UUID()
        let command = start(eventID, awaitsName: true)
        let json = try XCTUnwrap(String(data: try WristWire.encode(command), encoding: .utf8))
        XCTAssertTrue(json.contains("\"awaitsName\":true"), "fixture: the mark is on the wire: \(json)")
        let previous = try WristWire.decode(PreviousCommand.self, from: try WristWire.encode(command))
        XCTAssertEqual(previous.kind, .start(eventID: eventID, typeTitle: "Work", start: t0, end: t0 + 1800, title: nil))
    }

    func testAStartFromAWatchBeforeTheFieldDecodesUnmarked() throws {
        let eventID = UUID()
        let previous = PreviousCommand(id: UUID(), issuedAt: t0, kind: .start(
            eventID: eventID, typeTitle: "Work", start: t0, end: t0 + 1800, title: "Standup"
        ))
        let decoded = try WristWire.decode(WristCommand.self, from: try WristWire.encode(previous))
        XCTAssertEqual(decoded.kind, .start(eventID: eventID, typeTitle: "Work", start: t0, end: t0 + 1800, title: "Standup", awaitsName: nil))
    }

    func testANameLaterStartRoundTripsAndAPlainOneLeavesTheKeyOut() throws {
        let later = start(awaitsName: true)
        XCTAssertEqual(try WristWire.decode(WristCommand.self, from: try WristWire.encode(later)), later)
        let plain = try XCTUnwrap(String(data: try WristWire.encode(start()), encoding: .utf8))
        XCTAssertFalse(plain.contains("awaitsName"), plain)
    }

    func testTheOccurrenceFlagIsLeftOutWhenFalseAndReadsFalseWhenMissing() throws {
        var occurrence = WristOccurrence(
            id: "o", eventID: UUID(), title: "Work", type: "Work", colorHex: "#0A84FF",
            start: t0, end: t0 + 900, isInterrupt: false, quickActionsEnabled: true
        )
        let bare = try XCTUnwrap(String(data: try WristWire.encode(occurrence), encoding: .utf8))
        XCTAssertFalse(bare.contains("awaitsName"), bare)
        XCTAssertFalse(try WristWire.decode(WristOccurrence.self, from: Data(bare.utf8)).awaitsName)
        occurrence.awaitsName = true
        XCTAssertTrue(try WristWire.decode(WristOccurrence.self, from: try WristWire.encode(occurrence)).awaitsName)
    }

    // MARK: Applier and the watch's overlay

    func testOnlyANameLaterStartIsMarkedUnderTheTitleItStored() {
        let later = UUID(), plain = UUID(), named = UUID()
        XCTAssertEqual(WristCommandApplier.apply(start(later, awaitsName: true), to: store, defaults: defaults, awaitingNames: marks).outcome, .applied)
        WristCommandApplier.apply(start(plain), to: store, defaults: defaults, awaitingNames: marks)
        WristCommandApplier.apply(start(named, title: "Standup"), to: store, defaults: defaults, awaitingNames: marks)
        XCTAssertEqual(store.findCalendarEvent(id: later)?.title, "Work", "created exactly as a type-only start")
        XCTAssertEqual(marks.titles, [later: "Work"])
        XCTAssertTrue(marks.isAwaiting(store.findCalendarEvent(id: later)!))
        XCTAssertFalse(marks.isAwaiting(store.findCalendarEvent(id: plain)!))
    }

    func testARedeliveredStartDoesNotMarkAgain() {
        let eventID = UUID()
        WristCommandApplier.apply(start(eventID, awaitsName: true), to: store, defaults: defaults, awaitingNames: marks)
        marks.answer(eventID, name: nil, in: store)
        XCTAssertEqual(WristCommandApplier.apply(start(eventID, awaitsName: true), to: store, defaults: defaults, awaitingNames: marks).outcome, .duplicate)
        XCTAssertTrue(marks.titles.isEmpty, "an answered event is not asked again by a duplicate")
    }

    func testTheWatchDrawsItsPendingNameLaterBlockWaiting() {
        let snapshot = WristSnapshot(generatedAt: t0, types: [WristType(id: UUID(), title: "Work", colorHex: "#0A84FF")], occurrences: [], receipts: [])
        let later = WristPendingCommand(command: start(awaitsName: true))
        let plain = WristPendingCommand(command: WristCommand(id: UUID(), issuedAt: t0, kind: .start(
            eventID: UUID(), typeTitle: "Work", start: t0 + 1800, end: t0 + 3600
        )))
        let shown = WristStateReducer.overlaid(snapshot, pending: [later, plain], now: t0).occurrences
        XCTAssertEqual(shown.map(\.title), ["Work", "Work"])
        XCTAssertEqual(shown.map(\.awaitsName), [true, false])
    }

    func testTheSnapshotCarriesTheMarkOnlyWhileTheTitleIsUnchanged() {
        let eventID = UUID()
        WristCommandApplier.apply(start(eventID, awaitsName: true), to: store, defaults: defaults, awaitingNames: marks)
        func built() -> WristOccurrence? {
            WristSnapshotBuilder.occurrences(
                events: store.canvasRenderableCalendarEvents, now: t0, calendar: .current,
                awaitingNameTitles: marks.titles, colorHex: { _ in "#000000" }
            ).first { $0.eventID == eventID }
        }
        XCTAssertEqual(built()?.awaitsName, true)
        var renamed = store.findCalendarEvent(id: eventID)!
        renamed.title = "Planning"
        store.updateCalendarEvent(renamed)
        XCTAssertEqual(built()?.awaitsName, false)
    }

    func testTheBridgePushesTheMarkAndItsEnd() {
        let transport = FakeTransport()
        let bridge = WristBridge(ledger: WristAppliedLedger(defaults: defaults), defaults: defaults, transport: transport, awaitingNames: marks)
        let templates = EventTypeTemplateStore(defaults: defaults)
        let fixedNow = t0
        bridge.now = { fixedNow }
        bridge.attach(store: store, templates: templates)
        let eventID = UUID()
        bridge.handle(start(eventID, awaitsName: true))
        XCTAssertEqual(transport.pushed.last?.occurrences.first { $0.eventID == eventID }?.awaitsName, true)
        // Let the start's own debounced store push land first, so what
        // follows can only be the mark's change.
        let quiet = expectation(description: "start settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { quiet.fulfill() }
        wait(for: [quiet], timeout: 3)
        let before = transport.pushed.count
        // "Keep" changes no event: only the mark's own change can carry it.
        let settled = expectation(description: "debounced push")
        marks.answer(eventID, name: nil, in: store)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { settled.fulfill() }
        wait(for: [settled], timeout: 3)
        XCTAssertEqual(transport.pushed.count, before + 1, "the mark's end is pushed on its own")
        XCTAssertEqual(transport.pushed.last?.occurrences.first { $0.eventID == eventID }?.awaitsName, false)
        XCTAssertEqual(transport.pushed.last?.occurrences.first { $0.eventID == eventID }?.title, "Work")
    }

    private final class FakeTransport: WristSessionTransport {
        var isReadyForSnapshot = true
        var pushed: [WristSnapshot] = []
        func push(context: [String: Any]) throws {
            pushed.append(try WristWire.decode(WristSnapshot.self, from: context[WristWire.snapshotKey] as! Data))
        }
    }

    // MARK: When a mark ends

    private func markedEvent() -> Event {
        let event = Event(title: "Work", timeRanges: [.init(start: t0, end: t0 + 1800)], type: "Work")
        store.addCalendarEvent(event)
        marks.mark(event.id, title: event.title)
        return event
    }

    func testARenameFromAnywhereEndsTheWaitAndPruneDropsIt() {
        var event = markedEvent()
        XCTAssertTrue(marks.isAwaiting(event))
        event.title = "Planning"
        store.updateCalendarEvent(event)
        XCTAssertFalse(marks.isAwaiting(store.findCalendarEvent(id: event.id)!), "no path had to clear it")
        marks.prune(events: { self.store.findCalendarEvent(id: $0) })
        XCTAssertTrue(marks.marks.isEmpty)
    }

    func testTheSameTitleSavedOnTheEditSheetKeepsAsking() {
        let event = markedEvent()
        var touched = store.findCalendarEvent(id: event.id)!
        touched.note = "edited"
        store.updateCalendarEvent(touched)
        marks.prune(events: { self.store.findCalendarEvent(id: $0) })
        XCTAssertTrue(marks.isAwaiting(store.findCalendarEvent(id: event.id)!), "an edit that leaves the title is not an answer")
    }

    func testADeletedEventsMarkIsPruned() {
        let event = markedEvent()
        let other = markedEvent()
        store.deleteCalendarEvent(event)
        marks.prune(events: { self.store.findCalendarEvent(id: $0) })
        XCTAssertEqual(Set(marks.marks.keys), [other.id], "only the gone event's mark goes")
    }

    func testAMarkExpiresAfterItsLifetime() {
        let event = markedEvent()
        clock = t0 + AwaitingNameStore.lifetime - 60
        XCTAssertTrue(marks.isAwaiting(event), "control: still inside the lifetime")
        clock = t0 + AwaitingNameStore.lifetime + 60
        XCTAssertFalse(marks.isAwaiting(event))
        marks.prune(events: { self.store.findCalendarEvent(id: $0) })
        XCTAssertTrue(marks.marks.isEmpty)
    }

    func testThePromptsAnswers() {
        let named = markedEvent(), kept = markedEvent(), same = markedEvent(), blank = markedEvent()
        marks.answer(named.id, name: "  Planning ", in: store)
        marks.answer(kept.id, name: nil, in: store)
        marks.answer(same.id, name: "Work", in: store)
        XCTAssertEqual(store.findCalendarEvent(id: named.id)?.title, "Planning")
        XCTAssertEqual(store.findCalendarEvent(id: kept.id)?.title, "Work")
        XCTAssertEqual(store.findCalendarEvent(id: same.id)?.title, "Work")
        XCTAssertEqual(Set(marks.marks.keys), [blank.id], "every answer ends the wait; the unanswered one still asks")
    }

    func testMarksSurviveARelaunch() {
        let event = markedEvent()
        let reloaded = AwaitingNameStore(defaults: defaults, now: { [unowned self] in self.clock })
        XCTAssertTrue(reloaded.isAwaiting(event))
        reloaded.clear(event.id)
        XCTAssertTrue(AwaitingNameStore(defaults: defaults).marks.isEmpty)
    }

    func testAttachPrunesOnACalendarChange() {
        var event = markedEvent()
        marks.attach(to: store)
        XCTAssertFalse(marks.marks.isEmpty, "control: attach keeps a live mark")
        event.title = "Planning"
        store.updateCalendarEvent(event)
        let settled = expectation(description: "debounced prune")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { settled.fulfill() }
        wait(for: [settled], timeout: 3)
        XCTAssertTrue(marks.marks.isEmpty)
    }

    // MARK: Day timeline — the three paths

    private var today: Date { Calendar.current.startOfDay(for: Date()) }

    private func occurrence(_ title: String, hour: Double, id: UUID = UUID()) -> CalendarLayout.EventOccurrence {
        let start = today.addingTimeInterval(hour * 3600)
        let range = Event.TimeRange(start: start, end: start.addingTimeInterval(3600))
        return CalendarLayout.EventOccurrence(
            id: "\(title)-\(id.uuidString)", event: Event(id: id, title: title, timeRanges: [range], type: "Work"), range: range
        )
    }

    private func model(
        _ occurrences: [CalendarLayout.EventOccurrence], hourHeight: CGFloat = 56, awaiting: [UUID: String]
    ) -> DayLayerHostView.Model {
        DayLayerHostView.Model(
            date: today,
            occurrences: occurrences,
            contentWidth: 360,
            headerHeight: 16,
            hourHeight: hourHeight,
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
            frozenSlotMinutes: nil,
            awaitingNameTitles: awaiting
        )
    }

    func testTheRingAndBadgeAreDrawnOnEveryPathAndGoWithTheMark() {
        // A waiting block and a plain one in view; past the viewport a
        // waiting one and a plain one, brought in later by the cull.
        let a = occurrence("Work", hour: 1), b = occurrence("Gym", hour: 2.5)
        let c = occurrence("Work", hour: 20), d = occurrence("Read", hour: 21.5)
        let all = [a, b, c, d]
        let awaiting = [a.event.id: "Work", c.event.id: "Work"]

        let scroll = UIScrollView(frame: CGRect(x: 0, y: 0, width: 360, height: 300))
        scroll.contentSize = CGSize(width: 360, height: 2000)
        let host = DayLayerHostView(frame: CGRect(x: 0, y: 0, width: 360, height: 2000))
        scroll.addSubview(host)

        // Full render.
        host.apply(model(all, awaiting: awaiting))
        host.layoutIfNeeded()
        XCTAssertEqual(host.debugPaintCounts.render, 1, "fixture: the full render drew it")
        var drawn = host.debugAwaitingNameBlocks()
        XCTAssertEqual(drawn.ringed, [a.id], "c is past the viewport (no layers)")
        XCTAssertEqual(drawn.badged, [a.id])

        // Cheap vertical repaint (a pinch frame): the ring follows the new
        // height — a repaint that skipped it would leave the old geometry.
        host.apply(model(all, hourHeight: 80, awaiting: awaiting))
        host.layoutIfNeeded()
        XCTAssertEqual(host.debugPaintCounts.render, 1, "fixture: no full render")
        XCTAssertEqual(host.debugPaintCounts.repaintVertical, 1, "fixture: the cheap path drew it")
        drawn = host.debugAwaitingNameBlocks()
        XCTAssertEqual(drawn.ringed, [a.id])
        let heights = host.debugAwaitingNameRingHeight(a.id)
        XCTAssertGreaterThan(heights?.block ?? 0, 70, "fixture: the block grew with the pinch")
        XCTAssertEqual(heights?.ring ?? 0, (heights?.block ?? 0) - 1.5, accuracy: 0.01, "the ring is redrawn at the pinched height")

        // Viewport cull: scrolling c and d in builds their blocks there.
        host.apply(model(all, awaiting: awaiting))
        host.layoutIfNeeded()
        scroll.contentOffset = CGPoint(x: 0, y: 16 + 19.5 * 56)
        let culls = host.debugPaintCounts.cull
        let renders = host.debugPaintCounts.render, repaints = host.debugPaintCounts.repaintVertical
        XCTAssertTrue(host.debugRunCullPass())
        XCTAssertEqual(host.debugPaintCounts.cull, culls + 1, "fixture: the cull drew them")
        XCTAssertEqual(host.debugPaintCounts.render, renders, "fixture: no full render")
        XCTAssertEqual(host.debugPaintCounts.repaintVertical, repaints, "fixture: no repaint")
        drawn = host.debugAwaitingNameBlocks()
        XCTAssertTrue(drawn.ringed.contains(c.id), "the cull draws a waiting block it brings in")
        XCTAssertFalse(drawn.ringed.contains(d.id), "and leaves a plain one plain, even on a recycled subtree")
        XCTAssertTrue(drawn.badged.contains(c.id))

        // The mark going (no event change) redraws without it.
        host.apply(model(all, awaiting: [:]))
        host.layoutIfNeeded()
        XCTAssertTrue(host.debugAwaitingNameBlocks().ringed.isEmpty, "the mark's end alone repaints")
    }

    func testARenamedBlockIsNotDrawnWaiting() {
        let a = occurrence("Work", hour: 1)
        let host = DayLayerHostView(frame: CGRect(x: 0, y: 0, width: 360, height: 2000))
        host.apply(model([a], awaiting: [a.event.id: "Work"]))
        host.layoutIfNeeded()
        XCTAssertEqual(host.debugAwaitingNameBlocks().ringed, [a.id], "control")
        let renamed = occurrence("Planning", hour: 1, id: a.event.id)
        host.apply(model([renamed], awaiting: [a.event.id: "Work"]))
        host.layoutIfNeeded()
        XCTAssertTrue(host.debugAwaitingNameBlocks().ringed.isEmpty)
    }

    func testAShortBlockGetsTheRingButNoBadge() {
        let start = today.addingTimeInterval(3600)
        let range = Event.TimeRange(start: start, end: start.addingTimeInterval(15 * 60))
        let event = Event(title: "Work", timeRanges: [range], type: "Work")
        let short = CalendarLayout.EventOccurrence(id: "short", event: event, range: range)
        let host = DayLayerHostView(frame: CGRect(x: 0, y: 0, width: 360, height: 2000))
        host.apply(model([short], awaiting: [event.id: "Work"]))
        host.layoutIfNeeded()
        let drawn = host.debugAwaitingNameBlocks()
        XCTAssertEqual(drawn.ringed, ["short"])
        XCTAssertTrue(drawn.badged.isEmpty, "a quarter hour has no room for the badge")
    }
}
