//
//  CalendarTodoDetailNoteTests.swift
//  DoneTests
//
//  The todo detail page shows the same Note editor as an event's reflection
//  page (`detailNoteSection`), bound to the same `detailNoteText` and backed by
//  the same occurrence log record (`record.note`). The editor is only the
//  field: the load from the store (`loadDetailDraftIfNeeded`) and the save
//  back (`saveDetailNoteAndTemplate(coalesced: true)`) used to hang off
//  `reflectionPage` alone, which a todo never shows — so a todo's note opened
//  empty and nothing typed into it was ever written.
//
//  Driven through the real view on screen (the `EventStoreLookupIndexTests`
//  hosting idiom: a window on the host app's scene, a layout pass and a
//  run-loop turn), typing through the `UITextView` that backs the
//  `TextEditor`, so the path under test is the one a finger takes: UIKit edit
//  → SwiftUI binding → `onChange` → store → disk.
//
//  Every todo assertion has an event twin on the reflection page — the
//  positive control. If an event twin goes red, the rig is broken, not the
//  todo page.
//

import XCTest
import SwiftUI
import UIKit
@testable import Done

@MainActor
final class CalendarTodoDetailNoteTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var location: EventStorageLocation!

    override func setUp() {
        super.setUp()
        suiteName = "CalendarTodoDetailNoteTests-\(UUID().uuidString)"
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

    private func makeStore() -> EventStore {
        EventStore(defaults: defaults, storage: location, seedsSampleDataIfEmpty: false)
    }

    private let day = Date(timeIntervalSince1970: 1_770_000_000)

    /// A scheduled item of either kind. `note` is the event's OWN field (the
    /// edit form's Description) and is set to something the detail Note
    /// editor must never show, so a test can tell which field the editor is
    /// bound to.
    private func item(_ kind: Event.Kind) -> Event {
        Event(
            title: kind == .todo ? "Buy stamps" : "Deep Work",
            note: "description, not the detail note",
            timeRanges: [.init(start: day, end: day.addingTimeInterval(3600))],
            type: "Study",
            kind: kind
        )
    }

    private func occurrence(_ eventID: UUID) -> CalendarEventOccurrenceContext {
        CalendarEventOccurrenceContext(
            eventID: eventID,
            occurrenceDate: day,
            occurrenceID: nil,
            isAllDay: false,
            source: .timelineTap
        )
    }

    /// An event opens on its overview page; `.log` sends it to the reflection
    /// page, where its Note editor lives. A todo has one page whatever the
    /// target, so it gets the same route as an event would.
    private func route(for eventID: UUID) -> CalendarEventDetailRoute {
        CalendarEventDetailRoute(occurrence: occurrence(eventID), initialJumpTarget: .log)
    }

    private func logCommits(_ slots: [StorageSlot]) -> Int {
        slots.filter { $0 == .calendarEventLogRecords }.count
    }

    // MARK: - Host

    private func pump(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func renderDetailView(
        route: CalendarEventDetailRoute,
        store: EventStore
    ) -> (window: UIWindow, displaced: UIWindow?) {
        let controller = UIHostingController(
            rootView: CalendarEventDetailView(route: route).environmentObject(store)
        )
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let displaced = scene?.windows.first(where: \.isKeyWindow)
        let window = scene.map { UIWindow(windowScene: $0) }
            ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        pump(0.5)
        controller.view.layoutIfNeeded()
        pump(0.2)
        return (window, displaced)
    }

    /// Takes the page off screen the way a pop does — this is what runs the
    /// detail body's `onDisappear`, the lifecycle edge that flushes a pending
    /// coalesced note commit — then gives the host app its key window back.
    private func teardownHost(_ host: (window: UIWindow, displaced: UIWindow?)) {
        host.window.isHidden = true
        host.window.rootViewController = nil
        pump(0.05)
        host.displaced?.makeKeyAndVisible()
    }

    /// Every `UITextView` in the window that is actually on screen. The
    /// detail's Note `TextEditor` is one; nothing here assumes it is the only
    /// one on every page.
    private func visibleTextViews(in window: UIWindow) -> [UITextView] {
        var found: [UITextView] = []
        func walk(_ view: UIView) {
            if let textView = view as? UITextView, !textView.isHidden, textView.window != nil {
                let frame = textView.convert(textView.bounds, to: window)
                if frame.intersects(window.bounds) { found.append(textView) }
            }
            view.subviews.forEach(walk)
        }
        walk(window)
        return found
    }

    /// The detail Note editor. Found by elimination, not by its text, so a
    /// page that fails to LOAD the note still yields its editor for the save
    /// tests: the one editable text view that is not showing the event's own
    /// description.
    private func noteEditor(
        in window: UIWindow,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> UITextView {
        let candidates = visibleTextViews(in: window).filter {
            $0.isEditable && $0.text != "description, not the detail note"
        }
        XCTAssertEqual(
            candidates.count, 1,
            "expected exactly one on-screen Note editor, found \(candidates.count) "
            + "(texts: \(candidates.map { $0.text ?? "nil" })) — the rig is not looking at the "
            + "page it thinks it is",
            file: file, line: line
        )
        return try XCTUnwrap(candidates.first, file: file, line: line)
    }

    /// Types at the end of the editor the way the keyboard does: through
    /// `UITextInput`, so UIKit runs its delegate callbacks and SwiftUI's
    /// binding sees the edit. One run-loop turn per keystroke, so each one
    /// reaches the body as its own change.
    private func type(_ text: String, into editor: UITextView) {
        _ = editor.becomeFirstResponder()
        for character in text {
            editor.selectedRange = NSRange(location: (editor.text as NSString).length, length: 0)
            editor.insertText(String(character))
            pump(0.03)
        }
    }

    // MARK: - Load

    private func assertEditorOpensWithStoredNote(
        _ kind: Event.Kind,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let store = makeStore()
        let event = item(kind)
        store.addCalendarEvent(event)
        store.upsertLogRecord(for: occurrence(event.id)) { $0.note = "Bring the blue envelope" }
        let before = store.logRecord(for: occurrence(event.id))?.updatedAt

        var slots: [StorageSlot] = []
        store.onSlotCommitted = { slot, _ in slots.append(slot) }
        let host = renderDetailView(route: route(for: event.id), store: store)
        store.onSlotCommitted = nil
        defer { teardownHost(host) }

        let editor = try noteEditor(in: host.window, file: file, line: line)
        XCTAssertEqual(
            editor.text, "Bring the blue envelope",
            "the \(kind) detail's Note editor must open showing the occurrence's stored note",
            file: file, line: line
        )
        // Loading is not editing: putting the stored note into the editor
        // must not save it straight back (a fresh `updatedAt` on an unchanged
        // note is a write that sync would push as if it were new).
        XCTAssertEqual(logCommits(slots), 0,
                       "opening the \(kind) detail must not commit the log record",
                       file: file, line: line)
        XCTAssertEqual(store.logRecord(for: occurrence(event.id))?.updatedAt, before,
                       "opening the \(kind) detail must not touch the stored record",
                       file: file, line: line)
    }

    func testTodoDetailNoteOpensWithTheStoredNote() throws {
        try assertEditorOpensWithStoredNote(.todo)
    }

    /// Positive control: the reflection page has always loaded its note.
    func testEventReflectionNoteOpensWithTheStoredNote() throws {
        try assertEditorOpensWithStoredNote(.event)
    }

    // MARK: - Save

    /// Types into the Note editor, then takes the page away and boots a FRESH
    /// store on the same files — the relaunch after a pop — which must read
    /// what was typed. Also counts log-record commits during the typing burst:
    /// the note commit is coalesced (gh#219), so a burst of keystrokes must
    /// cost fewer commits than keystrokes; an uncoalesced save commits once
    /// per keystroke.
    private func assertTypedNoteIsSaved(
        _ kind: Event.Kind,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let keystrokes = "stamps"
        let store = makeStore()
        let event = item(kind)
        store.addCalendarEvent(event)
        let occ = occurrence(event.id)
        XCTAssertNil(store.logRecord(for: occ), "fixture: no log record before typing",
                     file: file, line: line)

        let host = renderDetailView(route: route(for: event.id), store: store)
        let editor = try noteEditor(in: host.window, file: file, line: line)

        var slots: [StorageSlot] = []
        store.onSlotCommitted = { slot, _ in slots.append(slot) }
        type(keystrokes, into: editor)
        store.onSlotCommitted = nil

        XCTAssertEqual(editor.text, keystrokes,
                       "fixture: the keystrokes must have landed in the editor itself",
                       file: file, line: line)
        XCTAssertEqual(
            store.logRecord(for: occ)?.note, keystrokes,
            "typing into the \(kind) detail's Note editor must reach the occurrence log record "
            + "in memory on the same turn",
            file: file, line: line
        )
        let commits = logCommits(slots)
        XCTAssertGreaterThan(commits, 0,
                             "the burst must commit at least once (the session's write-through)",
                             file: file, line: line)
        XCTAssertLessThan(
            commits, keystrokes.count,
            "the Note commit must be coalesced (gh#219): \(commits) log-record commits for "
            + "\(keystrokes.count) keystrokes",
            file: file, line: line
        )

        teardownHost(host)

        let reborn = makeStore()
        XCTAssertEqual(
            reborn.logRecord(for: occ)?.note, keystrokes,
            "after the page goes away, a store rebuilt from disk must read the typed note",
            file: file, line: line
        )
        XCTAssertEqual(reborn.findCalendarEvent(id: event.id)?.note, "description, not the detail note",
                       "the Note editor must not write the event's own description field",
                       file: file, line: line)
    }

    func testTodoDetailNoteTypingIsSaved() throws {
        try assertTypedNoteIsSaved(.todo)
    }

    /// Positive control: the reflection page has always saved its note.
    func testEventReflectionNoteTypingIsSaved() throws {
        try assertTypedNoteIsSaved(.event)
    }
}
