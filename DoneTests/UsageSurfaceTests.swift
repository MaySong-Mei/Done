//
//  UsageSurfaceTests.swift
//  DoneTests
//
//  gh#273 §6.3, the usage sites that live in views and in the app struct:
//    * Settings → Archived Features: a user's flip of a switch counts its
//      toggle key (and makes the feature available for the session); a
//      switch written any other way — a reset, an erase, a test — does not.
//      Driven through the real view's UISwitches, with programmatic writes
//      made while the view is on screen.
//    * The detail's Note editor: the load that fills it from the record is
//      not an edit, on the event's reflection page and on a todo's page
//      alike; typing is one use per page, not one per keystroke. Driven
//      through the real view's UITextView (the CalendarTodoDetailNoteTests
//      rig).
//    * Focus: DoneApp's `onChange(of: focusActive)` hook — the free function
//      it calls, driven directly, and a source anchor that pins what DoneApp
//      wires into it.
//

import XCTest
import SwiftUI
import UIKit
@testable import Done

// MARK: - Shared host

@MainActor
private enum UsageSurfaceHost {
    static func pump(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    static func show<V: View>(_ view: V) -> (window: UIWindow, displaced: UIWindow?) {
        let controller = UIHostingController(rootView: view)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let displaced = scene?.windows.first(where: \.isKeyWindow)
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
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

    static func hide(_ host: (window: UIWindow, displaced: UIWindow?)) {
        host.window.isHidden = true
        host.window.rootViewController = nil
        pump(0.05)
        host.displaced?.makeKeyAndVisible()
    }

    static func views<T: UIView>(_ type: T.Type, in window: UIWindow) -> [T] {
        var found: [T] = []
        func walk(_ view: UIView) {
            if let match = view as? T, !match.isHidden, match.window != nil,
               match.convert(match.bounds, to: window).intersects(window.bounds) {
                found.append(match)
            }
            view.subviews.forEach(walk)
        }
        walk(window)
        return found.sorted { $0.convert($0.bounds, to: window).minY < $1.convert($1.bounds, to: window).minY }
    }

    static func makeCenter(location: SpikeRunStorageLocation, countsLaunchSession: Bool) -> ResidentObservationCenter {
        let center = ResidentObservationCenter(
            coordinator: SpikeSessionCoordinator(), store: nil, location: location,
            installsFollowerProbe: false, verifiesSeed: false, seedTrail: { _ in },
            countsLaunchSession: countsLaunchSession, isAppForeground: { true }, availableGates: { [] }
        )
        center.activate()
        return center
    }
}

// MARK: - Settings → Archived Features

@MainActor
final class UsageArchivedSwitchTests: XCTestCase {
    private static let keys = [
        AppSettingsKeys.archivedFocusEnabled, AppSettingsKeys.archivedTodoStackEnabled,
        AppSettingsKeys.archivedWannaEnabled, AppSettingsKeys.archivedReportEnabled,
    ]
    private var saved: [String: Any] = [:]
    private var location: SpikeRunStorageLocation!
    private var center: ResidentObservationCenter?
    private var displacedSink: UsageSink?

    override func setUp() {
        super.setUp()
        // The switches live in the standard defaults (the view's @AppStorage);
        // whatever the host holds is put back afterwards.
        saved = [:]
        for key in Self.keys {
            if let value = UserDefaults.standard.object(forKey: key) { saved[key] = value }
            UserDefaults.standard.removeObject(forKey: key)
        }
        location = .ephemeral(id: UUID())
        displacedSink = UsageProbe.sink
    }

    override func tearDown() {
        center?.deactivate()
        center = nil
        UsageProbe.sink = displacedSink
        for key in Self.keys {
            if let value = saved[key] { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
        try? FileManager.default.removeItem(at: location.directory)
        super.tearDown()
    }

    private func count(_ name: String) -> Int { center?.usage.counts.count(name) ?? -1 }

    private var toggleTotal: Int {
        UsageGate.allCases.reduce(0) { total, gate in
            let names = ["usage.archived.use.\(gateName(gate))_on", "usage.archived.use.\(gateName(gate))_off"]
            return total + names.reduce(0) { $0 + count($1) }
        }
    }

    private func gateName(_ gate: UsageGate) -> String {
        UsageFeature.owner(of: gate).declaration.name
    }

    func testOnlyTheUsersFlipCountsAndAProgrammaticWriteNeverDoes() throws {
        center = UsageSurfaceHost.makeCenter(location: location, countsLaunchSession: true)
        let host = UsageSurfaceHost.show(NavigationStack { ArchivedFeaturesView() })
        defer { UsageSurfaceHost.hide(host) }
        let switches = UsageSurfaceHost.views(UISwitch.self, in: host.window)
        XCTAssertEqual(switches.count, 4, "the page's four switches, top to bottom: Focus, Todo stack, Wanna, Report")
        guard switches.count == 4 else { return }

        // Programmatic writes while the page is on screen: what a reset, an
        // erase or another writer does.
        UserDefaults.standard.set(true, forKey: AppSettingsKeys.archivedFocusEnabled)
        UsageSurfaceHost.pump(0.3)
        XCTAssertTrue(switches[0].isOn, "positive control for the rig: the page did see the programmatic write")
        UserDefaults.standard.removeObject(forKey: AppSettingsKeys.archivedFocusEnabled)
        UserDefaults.standard.set(true, forKey: AppSettingsKeys.archivedReportEnabled)
        UsageSurfaceHost.pump(0.3)
        XCTAssertFalse(switches[0].isOn)
        XCTAssertEqual(toggleTotal, 0, "a switch written by code is not the user deciding")
        XCTAssertEqual(count("usage.focus.available"), 0, "nor is it counted as turned on in this session")

        // The user's flips, through the switch itself.
        switches[1].setOn(true, animated: false)
        switches[1].sendActions(for: .valueChanged)
        UsageSurfaceHost.pump(0.3)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: AppSettingsKeys.archivedTodoStackEnabled), "the flip reached the switch")
        XCTAssertEqual(count("usage.archived.use.todo_stack_on"), 1)
        XCTAssertEqual(count("usage.todo_stack.available"), 1, "turned on in this session")
        switches[1].setOn(false, animated: false)
        switches[1].sendActions(for: .valueChanged)
        UsageSurfaceHost.pump(0.3)
        XCTAssertEqual(count("usage.archived.use.todo_stack_off"), 1)
        XCTAssertEqual(toggleTotal, 2, "two flips, nothing else")
    }
}

// MARK: - The detail's Note editor: load vs edit

@MainActor
final class UsageReflectionNoteEditTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var storage: EventStorageLocation!
    private var location: SpikeRunStorageLocation!
    private var center: ResidentObservationCenter?
    private var displacedSink: UsageSink?
    private let day = Date(timeIntervalSince1970: 1_770_000_000)

    override func setUp() {
        super.setUp()
        suiteName = "UsageReflectionNoteEditTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        storage = TestStorage.reset(suiteName)
        location = .ephemeral(id: UUID())
        displacedSink = UsageProbe.sink
    }

    override func tearDown() {
        center?.deactivate()
        center = nil
        UsageProbe.sink = displacedSink
        try? FileManager.default.removeItem(at: location.directory)
        TestStorage.tearDown(suiteName)
        super.tearDown()
    }

    private func occurrence(_ id: UUID) -> CalendarEventOccurrenceContext {
        CalendarEventOccurrenceContext(eventID: id, occurrenceDate: day, occurrenceID: nil, isAllDay: false, source: .timelineTap)
    }

    private func count(_ name: String) -> Int { center?.usage.counts.count(name) ?? -1 }

    private func noteEditor(in window: UIWindow) throws -> UITextView {
        let editors = UsageSurfaceHost.views(UITextView.self, in: window)
            .filter { $0.isEditable && $0.text != "description, not the detail note" }
        XCTAssertEqual(editors.count, 1, "exactly one on-screen Note editor (texts: \(editors.map { $0.text ?? "nil" }))")
        return try XCTUnwrap(editors.first)
    }

    private func type(_ text: String, into editor: UITextView) {
        _ = editor.becomeFirstResponder()
        for character in text {
            editor.selectedRange = NSRange(location: (editor.text as NSString).length, length: 0)
            editor.insertText(String(character))
            UsageSurfaceHost.pump(0.03)
        }
    }

    private func assertTheLoadIsNotAnEditAndTypingIsOneUse(_ kind: Event.Kind, counted: String, other: String) throws {
        center = UsageSurfaceHost.makeCenter(location: location, countsLaunchSession: false)
        let store = EventStore(defaults: defaults, storage: storage, seedsSampleDataIfEmpty: false)
        let event = Event(title: kind == .todo ? "Buy stamps" : "Deep Work", note: "description, not the detail note",
                          timeRanges: [.init(start: day, end: day.addingTimeInterval(3600))], type: "Study", kind: kind)
        store.addCalendarEvent(event)
        store.upsertLogRecord(for: occurrence(event.id)) { $0.note = "Bring the blue envelope" }

        let route = CalendarEventDetailRoute(occurrence: occurrence(event.id), initialJumpTarget: .log)
        let host = UsageSurfaceHost.show(CalendarEventDetailView(route: route).environmentObject(store))
        defer { UsageSurfaceHost.hide(host) }
        let editor = try noteEditor(in: host.window)
        XCTAssertEqual(editor.text, "Bring the blue envelope", "positive control: the \(kind) page loaded the stored note")
        XCTAssertEqual(count(counted), 0, "filling the editor from the record is not the user editing (\(kind))")
        XCTAssertEqual(count(other), 0)

        type("abc", into: editor)
        XCTAssertEqual(editor.text, "Bring the blue envelopeabc", "fixture: the keystrokes landed")
        XCTAssertEqual(count(counted), 1, "three keystrokes, one use (\(kind))")
        XCTAssertEqual(count(other), 0)
    }

    func testOnATodosPageTheLoadIsNotAnEditAndTypingIsOneTodoUse() throws {
        try assertTheLoadIsNotAnEditAndTypingIsOneUse(.todo, counted: "usage.event_detail.use.todo",
                                                      other: "usage.event_detail.use.reflect")
    }

    func testOnAnEventsReflectionPageTheLoadIsNotAnEditAndTypingIsOneReflectUse() throws {
        try assertTheLoadIsNotAnEditAndTypingIsOneUse(.event, counted: "usage.event_detail.use.reflect",
                                                      other: "usage.event_detail.use.todo")
    }
}

// MARK: - Focus: DoneApp's onChange(of: focusActive) hook

@MainActor
final class UsageFocusHookTests: XCTestCase {
    private var location: SpikeRunStorageLocation!
    private var center: ResidentObservationCenter?
    private var displacedSink: UsageSink?

    override func setUp() {
        super.setUp()
        location = .ephemeral(id: UUID())
        displacedSink = UsageProbe.sink
    }

    override func tearDown() {
        center?.deactivate()
        center = nil
        UsageProbe.sink = displacedSink
        try? FileManager.default.removeItem(at: location.directory)
        super.tearDown()
    }

    private func count(_ name: String) -> Int { center?.usage.counts.count(name) ?? -1 }

    func testTheHookEntersByTapOrRotationAndLeavesByRotationOrSystem() {
        center = UsageSurfaceHost.makeCenter(location: location, countsLaunchSession: false)

        doneRecordFocusUsage(active: true, manualFocusActive: true, landscapeFocusEffective: false)
        XCTAssertEqual(count("usage.focus.enter.tap"), 1, "the header button")
        XCTAssertEqual(count("usage.focus.enter.auto"), 0)
        doneRecordFocusUsage(active: false, manualFocusActive: false, landscapeFocusEffective: false)
        XCTAssertEqual(count("usage.focus.exit.system"), 1, "landscape focus not in effect: not a rotation")

        doneRecordFocusUsage(active: true, manualFocusActive: false, landscapeFocusEffective: true)
        XCTAssertEqual(count("usage.focus.enter.auto"), 1, "opened by the device's pose")
        XCTAssertEqual(count("usage.focus.enter.tap"), 1)
        doneRecordFocusUsage(active: false, manualFocusActive: false, landscapeFocusEffective: true)
        XCTAssertEqual(count("usage.focus.exit.rotate"), 1, "landscape focus still in effect: rotated back")

        // Focus archived mid-session: DoneApp notes the system exit first.
        doneRecordFocusUsage(active: true, manualFocusActive: false, landscapeFocusEffective: true)
        UsageProbe.noteExit(.focusSystem)
        doneRecordFocusUsage(active: false, manualFocusActive: false, landscapeFocusEffective: true)
        XCTAssertEqual(count("usage.focus.exit.system"), 2, "the archive switch's end is never a rotation")
        XCTAssertEqual(count("usage.focus.exit.rotate"), 1)

        // A preview still open when focus ends settles with it.
        doneRecordFocusUsage(active: true, manualFocusActive: true, landscapeFocusEffective: false)
        UsageProbe.enter(.focusPrecreatePill)
        doneRecordFocusUsage(active: false, manualFocusActive: false, landscapeFocusEffective: false)
        XCTAssertEqual(count("usage.focus_precreate.abandon"), 1)
        XCTAssertFalse(center!.usage.isVisitOpen(.focusPrecreate))
        XCTAssertEqual(count("usage.focus.abandon"), 4, "no visit here used anything")
    }

    /// What DoneApp hands the hook — the live manual flag and the EFFECTIVE
    /// landscape setting (setting AND archive switch) — and that archiving
    /// Focus notes the system exit before it ends the session. Comments are
    /// stripped, so a comment cannot satisfy the anchor.
    func testDoneAppWiresTheHookToTheEffectiveSettingAndNotesTheArchiveExit() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Done/DoneApp.swift")
        let code = UsageSourceScan.stripCommentsAndStrings(try String(contentsOf: url, encoding: .utf8))
        func closure(after anchor: String) -> String? {
            let chars = Array(code)
            guard let range = code.range(of: anchor) else { return nil }
            var i = code.distance(from: code.startIndex, to: range.upperBound)
            while i < chars.count, chars[i] != "{" { i += 1 }
            guard let body = UsageSourceScan.balanced(chars, from: i, "{", "}") else { return nil }
            return String(chars[body]).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        let focus = try XCTUnwrap(closure(after: ".onChange(of: focusActive)"), "the focusActive onChange")
        XCTAssertTrue(focus.contains("syncOrientationLock(focusActive: active)"), "liveness: the anchor found the right closure")
        XCTAssertTrue(focus.contains("doneRecordFocusUsage(active: active, manualFocusActive: orientationManager.manualFocusActive, landscapeFocusEffective: effectiveLandscapeFocusEnabled)"),
                      "the hook must get the live manual flag and the effective landscape setting: \(focus)")
        let archived = try XCTUnwrap(closure(after: ".onChange(of: archivedFocusEnabled)"), "the archive switch's onChange")
        let note = try XCTUnwrap(archived.range(of: "UsageProbe.noteExit(.focusSystem)"), "archiving notes the system exit: \(archived)")
        let end = try XCTUnwrap(archived.range(of: "orientationManager.endManualFocus()"))
        XCTAssertLessThan(note.lowerBound, end.lowerBound, "noted before the session is ended")
    }
}
