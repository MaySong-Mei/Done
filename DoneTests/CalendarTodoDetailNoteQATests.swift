//
//  CalendarTodoDetailNoteQATests.swift
//  DoneTests
//
//  Independent QA for fix/todo-detail-note: the Note editor's load
//  (`loadDetailDraftIfNeeded`) and save (`saveDetailNoteAndTemplate`) moved
//  from `reflectionPage` onto `detailNoteSection`, so a todo's single page,
//  which shows the same editor, loads and saves its note too.
//
//  Everything here goes through the real `CalendarEventDetailView` hosted in
//  a window on the test host's scene, typing through the `UITextView` behind
//  the `TextEditor`. The host view wraps the detail in an observable box, so
//  a test can swap the route in place (what `navigationDestination(item:)`
//  does when its item changes under a live destination) and drive the
//  `scenePhase` the detail's lifecycle flush listens to.
//
//  Three groups:
//    - Reflection page regression: what that page loaded and saved before the
//      move (the load firing with the editor off screen, template, effort and
//      completion written before typing, the open-writes-nothing gate) still
//      holds.
//    - Todo specifics: recurring, absorbed, Domino-pushed, put back to the
//      stack, opened twice, route swapped in place.
//    - Durability and sync: backgrounding and dismissal inside the 400 ms
//      coalescing window, a relaunch, the commit count of a burst, and the
//      `event_logs` row the sync engine builds.
//

import XCTest
import SwiftUI
import UIKit
import Combine
@testable import Done

@MainActor
private final class DetailHostBox: ObservableObject {
    @Published var route: CalendarEventDetailRoute
    @Published var phase: ScenePhase = .active

    init(route: CalendarEventDetailRoute) {
        self.route = route
    }
}

@MainActor
private struct DetailHost: View {
    @ObservedObject var box: DetailHostBox
    let store: EventStore

    var body: some View {
        CalendarEventDetailView(route: box.route)
            .environmentObject(store)
            .environment(\.scenePhase, box.phase)
    }
}

@MainActor
final class CalendarTodoDetailNoteQATests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var location: EventStorageLocation!

    override func setUp() {
        super.setUp()
        suiteName = "CalendarTodoDetailNoteQATests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        location = TestStorage.reset(suiteName)
    }

    override func tearDown() {
        TestStorage.tearDown(suiteName)
        defaults = nil
        suiteName = nil
        location = nil
        super.tearDown()
    }

    // MARK: - Fixtures

    private let itemDescription = "event description, never the detail note"

    /// 2026-02-02 02:40 UTC. No DST transition within the days used below.
    private let day = Date(timeIntervalSince1970: 1_770_000_000)
    private let oneDay: TimeInterval = 86_400

    private func makeStore() -> EventStore {
        EventStore(defaults: defaults, storage: location, seedsSampleDataIfEmpty: false)
    }

    private func item(
        _ kind: Event.Kind,
        title: String? = nil,
        start: Date? = nil,
        repeatUnit: Event.RepeatUnit = .none,
        agenticIntake: AgenticIntakeRecord? = nil
    ) -> Event {
        let s = start ?? day
        return Event(
            title: title ?? (kind == .todo ? "Buy stamps" : "Deep Work"),
            note: itemDescription,
            timeRanges: [.init(start: s, end: s.addingTimeInterval(3600))],
            repeatUnit: repeatUnit,
            repeatInterval: 1,
            type: "Study",
            kind: kind,
            agenticIntake: agenticIntake
        )
    }

    private func occurrence(_ eventID: UUID, at date: Date? = nil) -> CalendarEventOccurrenceContext {
        CalendarEventOccurrenceContext(
            eventID: eventID,
            occurrenceDate: date ?? day,
            occurrenceID: nil,
            isAllDay: false,
            source: .timelineTap
        )
    }

    private func route(_ eventID: UUID, at date: Date? = nil) -> CalendarEventDetailRoute {
        CalendarEventDetailRoute(occurrence: occurrence(eventID, at: date), initialJumpTarget: .log)
    }

    private func logCommits(_ slots: [StorageSlot]) -> Int {
        slots.filter { $0 == .calendarEventLogRecords }.count
    }

    private func records(of eventID: UUID, in store: EventStore) -> [CalendarEventLogRecord] {
        store.calendarEventLogRecords.filter { $0.eventID == eventID || $0.id.eventID == eventID }
    }

    // MARK: - Host

    private struct Host {
        let window: UIWindow
        let displaced: UIWindow?
        let box: DetailHostBox
    }

    private func pump(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func render(
        _ route: CalendarEventDetailRoute,
        store: EventStore,
        height: CGFloat = 852
    ) -> Host {
        let box = DetailHostBox(route: route)
        let controller = UIHostingController(rootView: DetailHost(box: box, store: store))
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let displaced = scene?.windows.first(where: \.isKeyWindow)
        let window = scene.map { UIWindow(windowScene: $0) }
            ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: height))
        window.frame = CGRect(x: 0, y: 0, width: 393, height: height)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        pump(0.5)
        controller.view.layoutIfNeeded()
        pump(0.2)
        return Host(window: window, displaced: displaced, box: box)
    }

    /// A pop: the page leaves the window, which runs the detail body's
    /// `onDisappear` (the lifecycle edge that flushes a pending note commit).
    private func teardown(_ host: Host) {
        host.window.endEditing(true)
        host.window.isHidden = true
        host.window.rootViewController = nil
        pump(0.05)
        host.displaced?.makeKeyAndVisible()
    }

    private func allTextViews(in window: UIWindow) -> [UITextView] {
        var found: [UITextView] = []
        func walk(_ view: UIView) {
            if let textView = view as? UITextView, !textView.isHidden, textView.window != nil {
                found.append(textView)
            }
            view.subviews.forEach(walk)
        }
        walk(window)
        return found
    }

    private func onScreen(_ view: UIView, in window: UIWindow) -> Bool {
        view.convert(view.bounds, to: window).intersects(window.bounds)
    }

    /// The detail Note editor: the one editable, on-screen text view that is
    /// not showing the item's own description. Found by elimination, not by
    /// its text, so a page that fails to LOAD still yields its editor.
    private func noteEditor(
        in window: UIWindow,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> UITextView {
        let candidates = allTextViews(in: window).filter {
            $0.isEditable && $0.text != itemDescription && onScreen($0, in: window)
        }
        XCTAssertEqual(
            candidates.count, 1,
            "rig: expected exactly one on-screen Note editor, found \(candidates.count) "
            + "(texts: \(candidates.map { $0.text ?? "nil" }))",
            file: file, line: line
        )
        return try XCTUnwrap(candidates.first, file: file, line: line)
    }

    /// Types at the end of the editor through `UITextInput`, one run-loop turn
    /// per keystroke. Returns when the last keystroke was delivered.
    @discardableResult
    private func type(_ text: String, into editor: UITextView, gap: TimeInterval = 0.03) -> Date {
        _ = editor.becomeFirstResponder()
        var last = Date()
        for character in text {
            editor.selectedRange = NSRange(location: (editor.text as NSString).length, length: 0)
            editor.insertText(String(character))
            last = Date()
            pump(gap)
        }
        return last
    }

    /// A record with every field the Note save writes or must leave alone.
    private func seedRichRecord(for occ: CalendarEventOccurrenceContext, in store: EventStore) {
        store.upsertLogRecord(for: occ) { record in
            record.note = "stored"
            record.selectedTemplateID = EventLogTemplateID.deepWork.rawValue
            record.templateAnswers = [
                "outcome": .string("shipped"),
                "focusQuality": .int(4)
            ]
            record.effort = 4
            record.completionStatus = .partial
            record.emotions = ["calm"]
            record.behaviors = ["proactive"]
            record.actualDurationMinutes = 42
            record.summary = "summary stays"
        }
    }

    // MARK: - 1. Reflection page regression

    /// The load runs when the page appears, not when the Note editor scrolls
    /// into view: in a short window the editor is below the fold and already
    /// holds the stored note. `detailExistingImages` is filled by the same
    /// call; the image strip itself is not asserted because this rig does not
    /// re-evaluate the reflection page after its first pass (on king too), so
    /// the strip never appears in the window whatever the load did.
    func testReflectionLoadRunsWhileTheNoteIsBelowTheFold() throws {
        let store = makeStore()
        let event = item(.event)
        store.addCalendarEvent(event)
        store.upsertLogRecord(for: occurrence(event.id)) { $0.note = "below the fold" }

        let host = render(route(event.id), store: store, height: 260)
        defer { teardown(host) }

        let editors = allTextViews(in: host.window).filter { $0.isEditable && $0.text == "below the fold" }
        XCTAssertEqual(editors.count, 1, "the reflection Note editor must hold the stored note even off screen")
        if let editor = editors.first {
            XCTAssertFalse(onScreen(editor, in: host.window),
                           "rig: the window must be short enough that the Note editor is off screen")
        }
    }

    /// Opening is not editing, on either page: the load must not write the
    /// record back, and every field must be exactly as stored.
    private func assertOpeningWritesNothing(_ kind: Event.Kind, file: StaticString = #filePath, line: UInt = #line) throws {
        let store = makeStore()
        let event = item(kind)
        store.addCalendarEvent(event)
        let occ = occurrence(event.id)
        seedRichRecord(for: occ, in: store)
        let before = try XCTUnwrap(store.logRecord(for: occ), file: file, line: line)

        var slots: [StorageSlot] = []
        store.onSlotCommitted = { slot, _ in slots.append(slot) }
        let host = render(route(event.id), store: store)
        pump(0.6) // past the 400 ms debounce, so a coalesced write would have landed
        store.onSlotCommitted = nil
        defer { teardown(host) }

        let editor = try noteEditor(in: host.window, file: file, line: line)
        XCTAssertEqual(editor.text, "stored", "the \(kind) Note editor opens on the stored note", file: file, line: line)
        XCTAssertEqual(logCommits(slots), 0, "opening the \(kind) detail must not commit the log record", file: file, line: line)
        XCTAssertEqual(store.logRecord(for: occ), before, "opening the \(kind) detail must leave the record untouched", file: file, line: line)
    }

    func testOpeningEventReflectionWritesNothing() throws { try assertOpeningWritesNothing(.event) }
    func testOpeningTodoDetailWritesNothing() throws { try assertOpeningWritesNothing(.todo) }

    /// Typing saves the note, and the template pick, its answers, effort,
    /// completion, tags, duration and summary ride through unchanged.
    private func assertTypingPreservesTheRestOfTheRecord(_ kind: Event.Kind, file: StaticString = #filePath, line: UInt = #line) throws {
        let store = makeStore()
        let event = item(kind)
        store.addCalendarEvent(event)
        let occ = occurrence(event.id)
        seedRichRecord(for: occ, in: store)
        let before = try XCTUnwrap(store.logRecord(for: occ), file: file, line: line)

        let host = render(route(event.id), store: store)
        let editor = try noteEditor(in: host.window, file: file, line: line)
        type(" more", into: editor)
        teardown(host)

        let after = try XCTUnwrap(makeStore().logRecord(for: occ), file: file, line: line)
        XCTAssertEqual(after.note, "stored more", "the \(kind) note must be saved", file: file, line: line)
        XCTAssertEqual(after.selectedTemplateID, before.selectedTemplateID, "template pick", file: file, line: line)
        XCTAssertEqual(after.templateAnswers, before.templateAnswers, "template answers", file: file, line: line)
        XCTAssertEqual(after.effort, 4, "effort", file: file, line: line)
        XCTAssertEqual(after.completionStatus, .partial, "completion", file: file, line: line)
        XCTAssertEqual(after.emotions, ["calm"], "emotions", file: file, line: line)
        XCTAssertEqual(after.behaviors, ["proactive"], "behaviors", file: file, line: line)
        XCTAssertEqual(after.actualDurationMinutes, 42, "duration", file: file, line: line)
        XCTAssertEqual(after.summary, "summary stays", "summary", file: file, line: line)
        XCTAssertEqual(after.id, before.id, "same record, same key", file: file, line: line)
    }

    func testEventTypingPreservesTemplateAndQuickFields() throws { try assertTypingPreservesTheRestOfTheRecord(.event) }
    func testTodoTypingPreservesTemplateAndQuickFields() throws { try assertTypingPreservesTheRestOfTheRecord(.todo) }

    /// Effort written before the page opened (no record yet, so the effort
    /// tap creates it) and completion written on the open page before the
    /// first keystroke, through the same store calls the detail's buttons
    /// make, must both survive the first note save.
    private func assertQuickWritesBeforeTypingSurvive(_ kind: Event.Kind, file: StaticString = #filePath, line: UInt = #line) throws {
        let store = makeStore()
        let event = item(kind)
        store.addCalendarEvent(event)
        let occ = occurrence(event.id)
        store.applyQuickEffort(2, for: occ)
        XCTAssertEqual(store.logRecord(for: occ)?.note, "", "fixture: the effort tap created a record with no note", file: file, line: line)

        let host = render(route(event.id), store: store)
        let editor = try noteEditor(in: host.window, file: file, line: line)
        XCTAssertEqual(editor.text, "", file: file, line: line)
        store.applyQuickCompletion(.skipped, for: occ)
        pump(0.1)
        type("after taps", into: editor)
        teardown(host)

        let after = try XCTUnwrap(makeStore().logRecord(for: occ), file: file, line: line)
        XCTAssertEqual(after.note, "after taps", "the \(kind) note must be saved", file: file, line: line)
        XCTAssertEqual(after.effort, 2, "effort written before the page opened", file: file, line: line)
        XCTAssertEqual(after.completionStatus, .skipped, "completion written before the first keystroke", file: file, line: line)
        XCTAssertEqual(records(of: event.id, in: store).count, 1, "one record for the occurrence", file: file, line: line)
    }

    func testEventQuickWritesBeforeTypingSurvive() throws { try assertQuickWritesBeforeTypingSurvive(.event) }
    func testTodoQuickWritesBeforeTypingSurvive() throws { try assertQuickWritesBeforeTypingSurvive(.todo) }

    // MARK: - 2. Todo specifics

    /// A recurring todo's note is the occurrence's: typed on day 2, it is on
    /// day 2's series key only, day 3 opens empty, day 2 reopens with it.
    func testRecurringTodoNoteIsKeyedToItsOccurrence() throws {
        let store = makeStore()
        let series = item(.todo, repeatUnit: .day)
        store.addCalendarEvent(series)
        XCTAssertTrue(store.findCalendarEvent(id: series.id)?.isRecurringSeries == true, "fixture: a recurring series")
        let day2 = day.addingTimeInterval(oneDay)
        let day3 = day.addingTimeInterval(2 * oneDay)

        let host = render(route(series.id, at: day2), store: store)
        let editor = try noteEditor(in: host.window)
        type("second day", into: editor)
        teardown(host)

        let reborn = makeStore()
        let record = try XCTUnwrap(reborn.logRecord(for: occurrence(series.id, at: day2)), "day 2's note must be saved")
        XCTAssertEqual(record.note, "second day")
        XCTAssertEqual(record.id.kind, .seriesOccurrence)
        XCTAssertEqual(record.id.dayKey, CalendarOccurrenceKey.dayKey(from: day2))
        XCTAssertNil(reborn.logRecord(for: occurrence(series.id, at: day3)), "day 3 must not share day 2's record")
        XCTAssertNil(reborn.logRecord(for: occurrence(series.id, at: day)), "day 1 must not share day 2's record")

        let other = render(route(series.id, at: day3), store: reborn)
        XCTAssertEqual(try noteEditor(in: other.window).text, "", "day 3 opens empty")
        teardown(other)

        let again = render(route(series.id, at: day2), store: reborn)
        XCTAssertEqual(try noteEditor(in: again.window).text, "second day", "day 2 reopens with its note")
        teardown(again)
    }

    /// Marking one day of a recurring todo done materializes a single-day
    /// exception with its own id (what the detail's Done toggle does via
    /// `applyRecurringEdit(.single)`). The canvas then routes that day by the
    /// exception's id; its detail must open on the note typed before, and
    /// typing there must extend the same record.
    func testRecurringTodoNoteFollowsTheDoneException() throws {
        let store = makeStore()
        let series = item(.todo, repeatUnit: .day)
        store.addCalendarEvent(series)
        let day2 = day.addingTimeInterval(oneDay)

        let host = render(route(series.id, at: day2), store: store)
        type("before done", into: try noteEditor(in: host.window))
        teardown(host)

        store.applyRecurringEdit(seriesEvent: try XCTUnwrap(store.findCalendarEvent(id: series.id)),
                                 occurrenceDate: day2, scope: .single) { event in
            event.isDone = true
            event.status = .completed
            event.completeAt = day2
        }
        let exception = try XCTUnwrap(store.rawCalendarEvents.first { $0.recurrenceParentId == series.id },
                                      "fixture: the done toggle materialized an exception")
        XCTAssertNotEqual(exception.id, series.id)
        XCTAssertEqual(exception.kind, .todo)

        let viaException = render(route(exception.id, at: day2), store: store)
        let editor = try noteEditor(in: viaException.window)
        XCTAssertEqual(editor.text, "before done", "the exception's detail must open on the occurrence's note")
        type(" after", into: editor)
        teardown(viaException)

        let reborn = makeStore()
        XCTAssertEqual(reborn.logRecord(for: occurrence(series.id, at: day2))?.note, "before done after")
        XCTAssertEqual(reborn.logRecord(for: occurrence(exception.id, at: day2))?.note, "before done after")
        XCTAssertEqual(reborn.calendarEventLogRecords.count, 1, "one record for the occurrence, not one per id")
    }

    /// A todo absorbed into an event while its detail is open keeps its own
    /// note; the parent event's record is not touched, and the parent's
    /// reflection Note editor does not show the todo's note.
    func testAbsorbedTodoKeepsItsOwnNote() throws {
        let store = makeStore()
        let parent = Event(title: "Errands", timeRanges: [.init(start: day.addingTimeInterval(-3600), end: day.addingTimeInterval(7200))],
                           type: "Study", kind: .event)
        let todo = item(.todo)
        store.addCalendarEvent(parent)
        store.addCalendarEvent(todo)

        let host = render(route(todo.id), store: store)
        let editor = try noteEditor(in: host.window)
        type("before", into: editor)
        store.absorbTodoIntoEvent(todoID: todo.id, parentEventID: parent.id, now: day.addingTimeInterval(-7200))
        pump(0.2)
        XCTAssertEqual(store.findCalendarEvent(id: todo.id)?.absorbedIntoEventID, parent.id, "fixture: absorbed")
        let editorAfter = try noteEditor(in: host.window)
        type(" after", into: editorAfter)
        teardown(host)

        let reborn = makeStore()
        XCTAssertEqual(reborn.logRecord(for: occurrence(todo.id))?.note, "before after")
        XCTAssertNil(reborn.logRecord(for: occurrence(parent.id)), "the parent event must not receive the todo's note")

        let reopened = render(route(todo.id), store: reborn)
        XCTAssertEqual(try noteEditor(in: reopened.window).text, "before after", "the absorbed todo reopens with its note")
        teardown(reopened)

        let parentPage = render(route(parent.id), store: reborn)
        XCTAssertEqual(try noteEditor(in: parentPage.window).text, "", "the parent's reflection note stays its own")
        teardown(parentPage)
    }

    /// The Domino push moves a parked todo to a later DAY, with the detail
    /// open mid-typing. The single-event key ignores the day, so the note must
    /// stay one record, keep its sync id, and reopen from the new day.
    func testDominoPushedTodoKeepsOneNoteAcrossTheDayChange() throws {
        let store = makeStore()
        let t0 = day
        store.dominoPushTodosPastHorizon(now: t0, horizonDays: 7) // stamps the first push
        let parkedStart = t0.addingTimeInterval(30 * oneDay)
        let todo = item(.todo, start: parkedStart)
        store.addCalendarEvent(todo)
        let keyBefore = CalendarOccurrenceKey.make(for: todo, occurrenceDate: parkedStart)

        let host = render(route(todo.id, at: parkedStart), store: store)
        type("parked", into: try noteEditor(in: host.window))
        store.dominoPushTodosPastHorizon(now: t0.addingTimeInterval(3 * oneDay), horizonDays: 7)
        pump(0.2)
        let pushed = try XCTUnwrap(store.findCalendarEvent(id: todo.id))
        let pushedStart = try XCTUnwrap(pushed.timeRanges.first?.start)
        XCTAssertEqual(pushedStart, parkedStart.addingTimeInterval(3 * oneDay), "fixture: the push moved the todo 3 days")
        let keyAfter = CalendarOccurrenceKey.make(for: pushed, occurrenceDate: pushedStart)
        XCTAssertNotEqual(keyBefore.dayKey, keyAfter.dayKey, "fixture: the day under the key changed")
        XCTAssertEqual(keyBefore, keyAfter, "a single todo's key ignores its day")

        type(" on", into: try noteEditor(in: host.window))
        teardown(host)

        let reborn = makeStore()
        let all = records(of: todo.id, in: reborn)
        XCTAssertEqual(all.count, 1, "one record across the push, not one per day")
        XCTAssertEqual(all.first?.note, "parked on")

        let reopened = render(route(todo.id, at: pushedStart), store: reborn)
        XCTAssertEqual(try noteEditor(in: reopened.window).text, "parked on", "the pushed todo reopens from its new day with the note")
        teardown(reopened)
    }

    /// Put back to the stack right after typing (the button calls
    /// `putTodoBackToStack` then dismisses), inside the coalescing window;
    /// then dragged out onto another day and reopened.
    func testPutBackToStackThenRescheduledTodoReopensWithItsNote() throws {
        let store = makeStore()
        let todo = item(.todo)
        store.addCalendarEvent(todo)

        let host = render(route(todo.id), store: store)
        type("keep me", into: try noteEditor(in: host.window))
        store.putTodoBackToStack(todoID: todo.id)
        teardown(host)
        XCTAssertTrue(store.findCalendarEvent(id: todo.id)?.isStackTodo == true, "fixture: back in the stack")

        let reborn = makeStore()
        XCTAssertEqual(reborn.logRecord(for: occurrence(todo.id))?.note, "keep me", "the note typed just before put-back is on disk")
        XCTAssertEqual(reborn.logRecord(for: occurrence(todo.id, at: Date()))?.note, "keep me",
                       "a stack todo's note is found whatever day the lookup names")

        var rescheduled = try XCTUnwrap(reborn.findCalendarEvent(id: todo.id))
        let newStart = day.addingTimeInterval(5 * oneDay)
        rescheduled.timeRanges = [.init(start: newStart, end: newStart.addingTimeInterval(1800))]
        reborn.updateCalendarEvent(rescheduled)

        let reopened = render(route(todo.id, at: newStart), store: reborn)
        let editor = try noteEditor(in: reopened.window)
        XCTAssertEqual(editor.text, "keep me", "the rescheduled todo reopens with its note")
        type(" again", into: editor)
        teardown(reopened)
        XCTAssertEqual(records(of: todo.id, in: makeStore()).map(\.note), ["keep me again"])
    }

    /// The canvas opens a tapped block with `initialJumpTarget: .meta`, not
    /// `.log`. A todo has one page either way, and its Note editor sits under
    /// the overview, done, deadline, put-back and absorption cards, so it may
    /// be below the fold: it must still load and save.
    func testTodoOpenedLikeATimelineTapLoadsAndSaves() throws {
        let store = makeStore()
        let todo = item(.todo)
        store.addCalendarEvent(todo)
        store.upsertLogRecord(for: occurrence(todo.id)) { $0.note = "from a tap" }

        let host = render(CalendarEventDetailRoute(occurrence: occurrence(todo.id), initialJumpTarget: .meta), store: store)
        let editors = allTextViews(in: host.window).filter { $0.isEditable && $0.text != itemDescription }
        XCTAssertEqual(editors.count, 1, "rig: one Note editor on the todo page (texts: \(editors.map { $0.text ?? "nil" }))")
        let editor = try XCTUnwrap(editors.first)
        XCTAssertEqual(editor.text, "from a tap", "the todo opened from a canvas tap shows its note")
        type(" and typed", into: editor)
        teardown(host)
        XCTAssertEqual(makeStore().logRecord(for: occurrence(todo.id))?.note, "from a tap and typed")
    }

    /// Two separate visits: the second opens on what the first typed, and
    /// what it adds lands on the same record.
    func testOpeningTheTodoDetailTwiceInARow() throws {
        let store = makeStore()
        let todo = item(.todo)
        store.addCalendarEvent(todo)

        let first = render(route(todo.id), store: store)
        type("one", into: try noteEditor(in: first.window))
        teardown(first)

        let second = render(route(todo.id), store: store)
        let editor = try noteEditor(in: second.window)
        XCTAssertEqual(editor.text, "one", "the second visit opens on the first visit's note")
        type(" two", into: editor)
        teardown(second)

        XCTAssertEqual(records(of: todo.id, in: makeStore()).map(\.note), ["one two"])
    }

    /// The route changes under a live detail (same view, new `route`), the
    /// way `navigationDestination(item:)` updates a presented destination
    /// when its item is reassigned. The editor must show the NEW item's note,
    /// and typing must not write the old item's note into the new one.
    private func assertRouteSwapLoadsTheNewNote(_ kind: Event.Kind, file: StaticString = #filePath, line: UInt = #line) throws {
        let store = makeStore()
        let a = item(kind, title: "A")
        let b = item(kind, title: "B")
        store.addCalendarEvent(a)
        store.addCalendarEvent(b)
        store.upsertLogRecord(for: occurrence(a.id)) { $0.note = "note A" }
        store.upsertLogRecord(for: occurrence(b.id)) { $0.note = "note B" }

        let host = render(route(a.id), store: store)
        defer { teardown(host) }
        XCTAssertEqual(try noteEditor(in: host.window, file: file, line: line).text, "note A",
                       "fixture: A's detail opens on A's note", file: file, line: line)

        host.box.route = route(b.id)
        pump(0.5)
        let editor = try noteEditor(in: host.window, file: file, line: line)
        // KNOWN FAILURE, pre-existing on the event reflection page and, with
        // this fix, on the todo page too: nothing resets `didLoadDetailDraft`
        // or the draft fields on a route change (`onChange(of: route.id)`
        // resets only the timeline composer), so the editor keeps A's note
        // and the next keystroke saves "note A!" into B. No UI path that
        // swaps the route under a live detail was found (every
        // `navigationDestination(item:)` source is covered by the pushed
        // detail). Strict: this goes red the day the swap is handled — then
        // drop the wrapper.
        XCTExpectFailure("route swap in place keeps the previous occurrence's note draft (pre-existing)") {
            XCTAssertEqual(editor.text, "note B", "after the swap the \(kind) editor must show B's note", file: file, line: line)
        }
        type("!", into: editor)
        pump(0.6)
        XCTAssertEqual(store.logRecord(for: occurrence(a.id))?.note, "note A", "A must be untouched", file: file, line: line)
        XCTExpectFailure("route swap in place saves the previous occurrence's note into the new one (pre-existing)") {
            XCTAssertNotEqual(store.logRecord(for: occurrence(b.id))?.note, "note A!",
                              "B must not receive A's note", file: file, line: line)
        }
    }

    func testRouteSwapInPlaceTodoToTodo() throws { try assertRouteSwapLoadsTheNewNote(.todo) }
    func testRouteSwapInPlaceEventToEvent() throws { try assertRouteSwapLoadsTheNewNote(.event) }

    // MARK: - 3. Durability

    /// Background mid-typing, inside the 400 ms window: the detail's
    /// scenePhase handler must land the owed commit before suspension.
    private func assertBackgroundingFlushes(_ kind: Event.Kind, file: StaticString = #filePath, line: UInt = #line) throws {
        let store = makeStore()
        let event = item(kind)
        store.addCalendarEvent(event)

        let host = render(route(event.id), store: store)
        defer { teardown(host) }
        let lastKey = type("stamps", into: try noteEditor(in: host.window, file: file, line: line))
        XCTAssertTrue(store.logRecordCommitPending,
                      "precondition: typing on the \(kind) page left a coalesced commit owed", file: file, line: line)

        host.box.phase = .background
        pump(0.03)
        let elapsed = Date().timeIntervalSince(lastKey)
        XCTAssertFalse(store.logRecordCommitPending, "backgrounding must flush the owed commit", file: file, line: line)
        XCTAssertLessThan(elapsed, 0.4, "rig: the flush must be observed before the debounce could have fired", file: file, line: line)
        XCTAssertEqual(makeStore().logRecord(for: occurrence(event.id))?.note, "stamps",
                       "the whole burst is on disk at suspension", file: file, line: line)
    }

    func testEventBackgroundingMidTypingFlushes() throws { try assertBackgroundingFlushes(.event) }
    func testTodoBackgroundingMidTypingFlushes() throws { try assertBackgroundingFlushes(.todo) }

    /// Dismiss inside the 400 ms window: the detail's onDisappear must land
    /// the owed commit.
    private func assertDismissInsideWindowFlushes(_ kind: Event.Kind, file: StaticString = #filePath, line: UInt = #line) throws {
        let store = makeStore()
        let event = item(kind)
        store.addCalendarEvent(event)

        let host = render(route(event.id), store: store)
        let lastKey = type("quick exit", into: try noteEditor(in: host.window, file: file, line: line))
        XCTAssertTrue(store.logRecordCommitPending, "precondition: a coalesced commit is owed", file: file, line: line)
        teardown(host)
        let elapsed = Date().timeIntervalSince(lastKey)
        XCTAssertFalse(store.logRecordCommitPending, "dismissal must flush the owed commit", file: file, line: line)
        XCTAssertLessThan(elapsed, 0.4, "rig: observed before the debounce could have fired", file: file, line: line)
        XCTAssertEqual(makeStore().logRecord(for: occurrence(event.id))?.note, "quick exit", file: file, line: line)
    }

    func testEventDismissInsideCoalescingWindowFlushes() throws { try assertDismissInsideWindowFlushes(.event) }
    func testTodoDismissInsideCoalescingWindowFlushes() throws { try assertDismissInsideWindowFlushes(.todo) }

    /// A kill after the debounce has fired (no lifecycle edge at all): the
    /// note is on disk, and a relaunched detail on a fresh store shows it.
    private func assertKillAndRelaunchReloads(_ kind: Event.Kind, file: StaticString = #filePath, line: UInt = #line) throws {
        let store = makeStore()
        let event = item(kind)
        store.addCalendarEvent(event)

        let host = render(route(event.id), store: store)
        type("survives a kill", into: try noteEditor(in: host.window, file: file, line: line))
        pump(0.7)
        XCTAssertFalse(store.logRecordCommitPending, "the trailing debounce has fired", file: file, line: line)

        // Kill: read the files with a fresh store while the old page is still
        // up, so no onDisappear or scenePhase flush has run.
        let relaunched = makeStore()
        XCTAssertEqual(relaunched.logRecord(for: occurrence(event.id))?.note, "survives a kill", file: file, line: line)
        teardown(host)

        let reopened = render(route(event.id), store: relaunched)
        XCTAssertEqual(try noteEditor(in: reopened.window, file: file, line: line).text, "survives a kill",
                       "the relaunched \(kind) detail shows the note", file: file, line: line)
        teardown(reopened)
    }

    func testEventKillAndRelaunchReloadsTheNote() throws { try assertKillAndRelaunchReloads(.event) }
    func testTodoKillAndRelaunchReloadsTheNote() throws { try assertKillAndRelaunchReloads(.todo) }

    /// A 20-keystroke burst costs about one commit plus one trailing commit,
    /// not one per keystroke, and typing writes no calendar-events commit.
    private func assertBurstIsCoalesced(_ kind: Event.Kind, file: StaticString = #filePath, line: UInt = #line) throws -> Int {
        let store = makeStore()
        let event = item(kind)
        store.addCalendarEvent(event)
        let host = render(route(event.id), store: store)
        defer { teardown(host) }
        let editor = try noteEditor(in: host.window, file: file, line: line)

        var slots: [StorageSlot] = []
        store.onSlotCommitted = { slot, _ in slots.append(slot) }
        let text = "twenty keystrokes ok"
        XCTAssertEqual(text.count, 20)
        type(text, into: editor)
        let burst = logCommits(slots)
        pump(0.7)
        let total = logCommits(slots)
        store.onSlotCommitted = nil

        XCTAssertEqual(store.logRecord(for: occurrence(event.id))?.note, text, file: file, line: line)
        XCTAssertGreaterThanOrEqual(burst, 1, "the burst writes through at least once", file: file, line: line)
        XCTAssertLessThanOrEqual(burst, 3, "\(burst) commits for 20 keystrokes on the \(kind) page: not coalesced", file: file, line: line)
        XCTAssertLessThanOrEqual(total - burst, 1, "at most one trailing commit", file: file, line: line)
        XCTAssertEqual(slots.filter { $0 == .calendarEvents }.count, 0,
                       "typing the note must not rewrite the calendar-events slot", file: file, line: line)
        return total
    }

    func testEventBurstIsCoalesced() throws { _ = try assertBurstIsCoalesced(.event) }
    func testTodoBurstIsCoalesced() throws { _ = try assertBurstIsCoalesced(.todo) }

    // MARK: - 4. Sync

    private func typeThroughDetail(_ text: String, eventID: UUID, store: EventStore) throws {
        let host = render(route(eventID), store: store)
        type(text, into: try noteEditor(in: host.window))
        teardown(host)
    }

    /// The todo's note must reach the `event_logs` row the sync engine builds
    /// and pushes, in the same shape an event's reflection note does, and the
    /// store's published log array (what the sync sink observes) must carry
    /// it.
    func testTodoNoteReachesTheEventLogsRowLikeAnEventNote() async throws {
        let store = makeStore()
        let todo = item(.todo)
        let event = item(.event, title: "Event twin", start: day.addingTimeInterval(7200))
        store.addCalendarEvent(todo)
        store.addCalendarEvent(event)

        var published: [[CalendarEventLogRecord]] = []
        let subscription = store.$calendarEventLogRecords.dropFirst().sink { published.append($0) }
        try typeThroughDetail("todo words", eventID: todo.id, store: store)
        try typeThroughDetail("event words", eventID: event.id, store: store)
        subscription.cancel()
        XCTAssertTrue(published.contains { $0.contains { $0.eventID == todo.id && $0.note == "todo words" } },
                      "the store's published log array (the sync sink's input) must carry the todo note")

        let uid = "44444444-4444-4444-4444-444444444444"
        let server = SyncFakeServer(userId: uid)
        let service = SupabaseSyncService(gateway: server, userId: uid, defaults: defaults, environment: .local)
        await service.syncLogs(store.calendarEventLogRecords)

        let todoRecord = try XCTUnwrap(store.logRecord(for: occurrence(todo.id)))
        let eventRecord = try XCTUnwrap(store.logRecord(for: occurrence(event.id)))
        let todoKey = service.encodeOccurrenceKey(todoRecord.id)
        let eventKey = service.encodeOccurrenceKey(eventRecord.id)
        XCTAssertEqual(todoKey, "single|\(todo.id.uuidString)")

        let todoRow = try XCTUnwrap(server.row(table: "event_logs", key: todoKey), "the todo's log row must reach the server")
        let eventRow = try XCTUnwrap(server.row(table: "event_logs", key: eventKey), "control: the event's log row reaches the server")
        XCTAssertEqual(todoRow.data["note"] as? String, "todo words")
        XCTAssertEqual((todoRow.data["event_id"] as? String)?.lowercased(), todo.id.uuidString.lowercased())
        XCTAssertEqual(eventRow.data["note"] as? String, "event words")
        XCTAssertEqual(Set(todoRow.data.keys), Set(eventRow.data.keys), "the todo row has the event row's shape")
        XCTAssertEqual(service.logToRow(todoRecord)["note"] as? String, "todo words", "the row builder")
    }
}
