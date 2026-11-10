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

// MARK: - Writes that run after the detail has gone, and programmatic page writes

/// The detail pushed and popped the way a presenter does it (the
/// `UsageDetailNavigationTests` rig). Two writes the detail defers until it
/// disappears — the deadline scrub's coalesced commit, the name prompt's
/// save of a typed but unsaved name — run AFTER the presenter's leave has
/// settled the visit. The use must already be on the visit by then, counted
/// at the user's action. And the route jump that rewrites the page on every
/// return from a pushed page is not the user viewing it.
@MainActor
final class UsageDetailLateWriteTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var storage: EventStorageLocation!
    private var location: SpikeRunStorageLocation!
    private var center: ResidentObservationCenter?
    private var displacedSink: UsageSink?
    private let day = Date(timeIntervalSince1970: 1_770_000_000)

    override func setUp() {
        super.setUp()
        suiteName = "UsageDetailLateWriteTests-\(UUID().uuidString)"
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

    private func count(_ name: String) -> Int { center?.usage.counts.count(name) ?? -1 }

    private func settle() { UsageSurfaceHost.pump(1.0) }

    /// Pumps until `condition` holds or `timeout` passes: a pop with the
    /// keyboard up takes longer than a fixed wait reliably covers.
    private func wait(upTo timeout: TimeInterval, for condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { UsageSurfaceHost.pump(0.1) }
    }

    private func route(_ id: UUID, _ target: CalendarEventDetailJumpTarget) -> CalendarEventDetailRoute {
        CalendarEventDetailRoute(
            occurrence: CalendarEventOccurrenceContext(eventID: id, occurrenceDate: day, occurrenceID: nil,
                                                       isAllDay: false, source: .timelineTap),
            initialJumpTarget: target)
    }

    private func open(_ event: Event, _ target: CalendarEventDetailJumpTarget)
        -> (store: EventStore, nav: UsageDetailNavigationTests.Nav, host: (window: UIWindow, displaced: UIWindow?)) {
        center = UsageSurfaceHost.makeCenter(location: location, countsLaunchSession: false)
        let store = EventStore(defaults: defaults, storage: storage, seedsSampleDataIfEmpty: false)
        store.rawCalendarEvents = [event]
        let nav = UsageDetailNavigationTests.Nav()
        let host = UsageSurfaceHost.show(UsageDetailNavigationTests.Host(nav: nav, store: store))
        UsageProbe.enter(.eventDetailCanvas)
        nav.path = [.detail(route(event.id, target))]
        settle()
        return (store, nav, host)
    }

    func testADeadlineScrubIsAUseOfTheVisitEvenWhenItsCommitRunsAfterTheLeave() throws {
        let deadline = day.addingTimeInterval(7_200)
        let todo = Event(title: "Buy stamps", timeRanges: [.init(start: day, end: day.addingTimeInterval(3600))],
                         deadline: deadline, type: "Study", kind: .todo)
        let (store, nav, host) = open(todo, .meta)
        defer { UsageSurfaceHost.hide(host) }
        let picker = try XCTUnwrap(UsageSurfaceHost.views(UIDatePicker.self, in: host.window).first,
                                   "the todo page's deadline picker")
        picker.date = deadline.addingTimeInterval(3_600)
        picker.sendActions(for: .valueChanged)
        UsageSurfaceHost.pump(0.05)
        XCTAssertEqual(count("usage.event_detail.use.todo"), 1, "the scrub is the use, at the scrub")

        // Back within the coalescer's window: its commit runs on the way out.
        nav.path = []
        wait(upTo: 4) { store.findCalendarEvent(id: todo.id)?.deadline == deadline.addingTimeInterval(3_600) }
        XCTAssertEqual(store.findCalendarEvent(id: todo.id)?.deadline, deadline.addingTimeInterval(3_600),
                       "positive control: the coalesced commit did run, after the page went away")
        XCTAssertEqual(count("usage.event_detail.abandon"), 0, "a visit with a scrub was not abandoned")
        XCTAssertEqual(count("usage.event_detail.use.todo"), 1, "and the late commit adds no second, stray use")
    }

    func testANameTypedAndLeftUnsavedIsAUseOfTheVisitNotAStrayUseAfterIt() throws {
        let event = Event(title: "Workout", timeRanges: [.init(start: day, end: day.addingTimeInterval(3600))], type: "Study")
        AwaitingNameStore.shared.mark(event.id, title: event.title)
        defer { AwaitingNameStore.shared.clear(event.id) }
        let (store, nav, host) = open(event, .meta)
        // Prune the mark against this test's store, not the host app's.
        AwaitingNameStore.shared.attach(to: store)
        defer { UsageSurfaceHost.hide(host) }
        let field = try XCTUnwrap(UsageSurfaceHost.views(UITextField.self, in: host.window).first { $0.placeholder == "Workout" },
                                  "the name prompt's field")
        _ = field.becomeFirstResponder()
        for character in "Lunch" {
            field.insertText(String(character))
            UsageSurfaceHost.pump(0.03)
        }
        XCTAssertEqual(count("usage.event_detail.use.plan"), 1, "typing the name is the use, once")

        nav.path = []
        wait(upTo: 4) { store.findCalendarEvent(id: event.id)?.title == "Lunch" }
        XCTAssertEqual(store.findCalendarEvent(id: event.id)?.title, "Lunch",
                       "positive control: the prompt saved the typed name on the way out")
        XCTAssertEqual(count("usage.event_detail.abandon"), 0)
        XCTAssertEqual(count("usage.event_detail.use.plan"), 1, "the save on the way out is not a second use")
    }

    /// The route replaced in place, as `navigationDestination(item:)` does
    /// when its item changes: the detail's `onChange(of: route.id)` re-runs
    /// the route jump — the same programmatic page write a return from the
    /// chat page makes.
    final class ItemNav: ObservableObject {
        @Published var route: CalendarEventDetailRoute?
    }

    struct ItemHost: View {
        @ObservedObject var nav: ItemNav
        let store: EventStore
        var body: some View {
            NavigationStack {
                Color.clear.navigationDestination(item: $nav.route) { route in
                    CalendarEventDetailView(route: route).environmentObject(store)
                }
            }
        }
    }

    /// Which page the detail shows: the pager's offset, in pages.
    private func shownPage(in window: UIWindow) -> Int? {
        guard let pager = UsageSurfaceHost.views(UICollectionView.self, in: window).first(where: { $0.isPagingEnabled }),
              pager.bounds.width > 0 else { return nil }
        return Int((pager.contentOffset.x / pager.bounds.width).rounded())
    }

    /// Opening straight onto the reflection page (Log, an occurrence row) is
    /// a view: the user's entry chose the page. So is a new route replacing
    /// the old one in place. What is not — the route re-asserting its page on
    /// a re-appear — needs a finger first and is driven in
    /// `UsageRouteJumpTests`.
    func testTheRoutesOwnPageChoiceIsAView() throws {
        center = UsageSurfaceHost.makeCenter(location: location, countsLaunchSession: false)
        let store = EventStore(defaults: defaults, storage: storage, seedsSampleDataIfEmpty: false)
        let event = Event(title: "Deep Work", timeRanges: [.init(start: day, end: day.addingTimeInterval(3600))], type: "Study")
        store.rawCalendarEvents = [event]
        let nav = ItemNav()
        let host = UsageSurfaceHost.show(ItemHost(nav: nav, store: store))
        defer { UsageSurfaceHost.hide(host) }

        UsageProbe.enter(.eventDetailMenu)
        nav.route = route(event.id, .log)
        settle()
        XCTAssertEqual(shownPage(in: host.window), 1, "rig: opened on the reflection page by the route")
        XCTAssertEqual(count("usage.event_detail.view.reflection"), 1, "the entry chose the reflection page: a view")

        nav.route = route(event.id, .meta)
        settle()
        XCTAssertEqual(shownPage(in: host.window), 0, "rig: the new route opened the overview")
        XCTAssertEqual(count("usage.event_detail.view.reflection"), 1, "the overview is not the reflection page")
        nav.route = route(event.id, .log)
        settle()
        XCTAssertEqual(shownPage(in: host.window), 1)
        XCTAssertEqual(count("usage.event_detail.view.reflection"), 2, "a new route onto the reflection page is a view too")
    }
}

// MARK: - Each presenter settles the detail's visit

/// One anchor per presenter, comments stripped: a single surviving leave
/// somewhere must not satisfy the other two.
@MainActor
final class UsageDetailPresenterAnchorTests: XCTestCase {
    private func source(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(path)
        return UsageSourceScan.stripCommentsAndStrings(try String(contentsOf: url, encoding: .utf8))
    }

    private func closures(after anchor: String, in code: String) -> [String] {
        let chars = Array(code)
        var found: [String] = []
        var searchFrom = code.startIndex
        while let range = code.range(of: anchor, range: searchFrom..<code.endIndex) {
            var i = code.distance(from: code.startIndex, to: range.upperBound)
            while i < chars.count, chars[i] != "{" { i += 1 }
            if let body = UsageSourceScan.balanced(chars, from: i, "{", "}") {
                found.append(String(chars[body]).split(whereSeparator: \.isWhitespace).joined(separator: " "))
            }
            searchFrom = range.upperBound
        }
        return found
    }

    private func assertLeaves(_ path: String, routeState: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let code = try source(path)
        let bodies = closures(after: ".onChange(of: \(routeState))", in: code)
        XCTAssertFalse(bodies.isEmpty, "\(path): no onChange of \(routeState)", file: file, line: line)
        let leaves = bodies.filter { $0.contains("oldValue != nil, newValue == nil") && $0.contains("UsageProbe.leave(.eventDetail)") }
        XCTAssertEqual(leaves.count, 1, "\(path): the route going away must settle the detail's visit", file: file, line: line)
    }

    func testTheCalendarPageSettlesTheDetailWhenItsRouteGoesAway() throws {
        try assertLeaves("Done/Views/Calendar/CalendarPageView.swift", routeState: "selectedEventDetailRoute")
    }

    func testTheSearchSettlesTheDetailWhenItsRouteGoesAway() throws {
        try assertLeaves("Done/Views/Calendar/CalendarSearchView.swift", routeState: "detailRoute")
    }

    func testTheListSettlesTheDetailWhenItsRouteGoesAway() throws {
        try assertLeaves("Done/Views/Calendar/Components/CalendarListView.swift", routeState: "selectedEventDetailRoute")
    }
}

// MARK: - Erase through the real eraser (design §11 item 7)

@MainActor
final class UsageEraseThroughTheEraserTests: XCTestCase {
    private let uid = TelemetryFixtures.uid
    private let bundleID = Bundle.main.bundleIdentifier ?? "wordless.shiqiliuyifanmei.app"
    private let pool = SpikeRunStorageLocation.production
    private var savedStandard: [String: Any]?
    private var suite = ""
    private var defaults: UserDefaults!
    private var store: EventStore!
    private var center: ResidentObservationCenter?
    private var displacedSink: UsageSink?
    private var scratch: [URL] = []

    override func setUp() {
        super.setUp()
        savedStandard = UserDefaults.standard.persistentDomain(forName: bundleID)
        SpikeRunStore.wipe(location: pool)
        suite = "UsageEraseThroughTheEraserTests-\(UUID().uuidString)"
        let location = TestStorage.reset(suite)
        defaults = UserDefaults(suiteName: suite)!
        store = EventStore(defaults: defaults, storage: location, seedsSampleDataIfEmpty: false)
        displacedSink = UsageProbe.sink
    }

    override func tearDown() {
        center?.deactivate()
        center = nil
        UsageProbe.sink = displacedSink
        SpikeRunStore.wipe(location: pool)
        UserDefaults.standard.setPersistentDomain(savedStandard ?? [:], forName: bundleID)
        for url in scratch { try? FileManager.default.removeItem(at: url) }
        TestStorage.tearDown(suite)
        super.tearDown()
    }

    private func temporaryDirectory(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("UsageEraseThroughTheEraserTests-\(name)-\(UUID().uuidString)", isDirectory: true)
        scratch.append(url)
        return url
    }

    /// The same eraser `SpikeEraseWritebackTests` drives.
    private func makeEraser() -> LocalDataEraser {
        let types = EventTypeTemplateStore(defaults: defaults)
        let skills = SkillInsightStore(defaults: defaults)
        let prefs = AgentPreferenceStore(directoryURL: temporaryDirectory("prefs"))
        let service = SupabaseSyncService(gateway: SyncFakeServer(userId: uid).connection(), userId: uid,
                                          defaults: .standard, scheduler: SyncManualScheduler(start: Date()),
                                          environment: .local)
        let expiresAt = Date().addingTimeInterval(3_600).timeIntervalSince1970
        let session = #"{"access_token":"at-1","refresh_token":"r-1","user_id":"\#(uid)","email":"erase@example.com","expires_at":\#(expiresAt)}"#
        let auth = AuthService(url: "https://stub.invalid", projectAPIKey: "test-publishable-key", defaults: defaults,
                               sessionStore: InMemorySessionStore(),
                               transport: { request in
                                   XCTFail("no auth request may go out; got \(request.url?.absoluteString ?? "?")")
                                   throw URLError(.notConnectedToInternet)
                               },
                               launchEnvironment: ["SYNC_DEBUG_SESSION": session], syncEnvironment: .local)
        let snapshotDirectory = temporaryDirectory("snapshot")
        try? FileManager.default.createDirectory(at: snapshotDirectory, withIntermediateDirectories: true)
        let snapshots = BackupSnapshotService()
        snapshots.snapshotFileURLOverride = snapshotDirectory.appendingPathComponent("backup-snapshot.json")
        return LocalDataEraser(store: store, skillStore: skills,
                               agentRuntime: AgentRuntime(eventTypeTemplateStore: types, preferenceStore: prefs),
                               authService: auth, calendarState: CalendarViewState(defaults: defaults),
                               syncService: service, imageBackupCoordinator: ImageBackupCoordinator(defaults: defaults),
                               backupSnapshotService: snapshots)
    }

    func testTheEraseForgetsTheUsageCountsAndTheOpenVisits() throws {
        let user = uid
        let made = ResidentObservationCenter(
            coordinator: SpikeSessionCoordinator(), store: nil, location: pool,
            ownerUID: { user }, installsFollowerProbe: false, verifiesSeed: false, seedTrail: { _ in },
            countsLaunchSession: true, isAppForeground: { true }, availableGates: { [] }
        )
        made.activate()
        center = made
        XCTAssertTrue(ResidentObservationCenter.shared === made, "fixture: the eraser reaches this center")
        UsageProbe.enter(.eventDetailCanvas)
        UsageProbe.use(.repeatForm)
        made.flushDaily()
        XCTAssertEqual(SpikeRunStore.loadRuns(spikeID: UsageRecordIDs.spikeID, location: pool).count, 1,
                       "fixture: the pre-erase day is on disk")

        makeEraser().resetAllLocalData(keepingSession: true)

        UsageProbe.use(.eventDetailPlan)                 // a late write for the erased owner's visit
        UsageProbe.leave(.eventDetail)                   // and that visit's end
        made.flushDaily()
        let after = try XCTUnwrap(SpikeRunStore.loadRuns(spikeID: UsageRecordIDs.spikeID, location: pool).first)
        XCTAssertEqual(SpikeRunStore.loadRuns(spikeID: UsageRecordIDs.spikeID, location: pool).count, 1, "only the new day's line")
        XCTAssertEqual(after.metrics, ["sessions": .number(1)],
                       "nothing from before the erase; the open visit settled nothing; the session the erase ran in is the new record's denominator")
    }
}

// MARK: - Effort: the user's release is the use, not the commit

/// Three paths reach the effort commit: the user's release (or tap), a
/// gesture cancelled mid-drag (Home pressed, the scroll view winning), and
/// the backgrounding flush of a drag in progress. Only the first is the user
/// deciding; an interrupted drag is not a use even though its value is
/// written. A live gesture cannot be driven from a test, so each path is
/// driven through its own seam: the scrubber's `handleEnded` (only `.onEnded`
/// calls it) and `handleDragActiveChanged` (the reset a cancellation also
/// delivers), and the control's `commitDrag` (the scrubber's commit and the
/// flush) vs `handleRelease`.
@MainActor
final class UsageEffortReleaseTests: XCTestCase {
    private final class Recorder {
        var value: Int?
        var commits: [Int] = []
        var releases: [Int] = []
        init(_ value: Int?) { self.value = value }
    }

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

    private func scrubber(_ recorder: Recorder) -> CalendarEffortScrubber {
        CalendarEffortScrubber(value: Binding(get: { recorder.value }, set: { recorder.value = $0 }),
                               onCommit: { recorder.commits.append($0) },
                               onRelease: { recorder.releases.append($0) })
    }

    func testTheScrubberReportsTheUsersReleaseAndNeverACancellation() {
        let released = Recorder(2)
        let drag = scrubber(released)
        drag.handleChanged(locationX: 70, trackWidth: 100)
        drag.handleEnded(locationX: 100, trackWidth: 100)          // .onEnded: the finger lifted
        drag.handleDragActiveChanged(wasActive: true, isActive: false)
        XCTAssertEqual(released.releases, [5], "the release, with the released value")
        XCTAssertEqual(released.commits, [5], "positive control: and the commit")

        let cancelled = Recorder(2)
        let interrupted = scrubber(cancelled)
        interrupted.handleChanged(locationX: 70, trackWidth: 100)
        interrupted.handleDragActiveChanged(wasActive: true, isActive: false)   // no .onEnded for a cancellation
        XCTAssertEqual(cancelled.commits, [4], "the cancelled drag still commits its value")
        XCTAssertEqual(cancelled.releases, [], "but it is not a release")
    }

    func testOnlyTheReleaseCountsTheEffortUseNeitherTheCancelNorTheFlushCommit() {
        center = UsageSurfaceHost.makeCenter(location: location, countsLaunchSession: false)
        let count = { self.center?.usage.counts.count("usage.event_detail.use.reflect") ?? -1 }
        var commits = 0
        let control = CalendarEffortQuickControl(storedEffort: 2, tint: .blue, onCommit: { _ in commits += 1 })
        control.commitDrag(4)            // a cancelled drag's commit
        control.commitDrag(4)            // the backgrounding flush: the same call
        XCTAssertEqual(commits, 2, "fixture: both reached the durable commit")
        XCTAssertEqual(count(), 0, "an interrupted drag is not a use")

        control.handleRelease(2)
        XCTAssertEqual(count(), 0, "released on the stored value: nothing changed")
        control.handleRelease(4)
        XCTAssertEqual(count(), 1, "positive control: the user's release that moves the value is one use")
    }

    /// The wiring a direct-construction test cannot reach, as a comment-blind
    /// anchor: the release is what counts, and no commit path does.
    func testNoCommitPathCountsAndTheScrubbersReleaseIsWiredToTheControl() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        func code(_ path: String) throws -> String {
            UsageSourceScan.stripCommentsAndStrings(try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8))
        }
        func body(of signature: String, in source: String) throws -> String {
            let chars = Array(source)
            let range = try XCTUnwrap(source.range(of: signature), "\(signature) not found")
            var i = source.distance(from: source.startIndex, to: range.upperBound)
            while i < chars.count, chars[i] != "{" { i += 1 }
            let inner = try XCTUnwrap(UsageSourceScan.balanced(chars, from: i, "{", "}"))
            return String(chars[inner]).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        let glass = try code("Done/Views/Calendar/Components/GlassCardView.swift")
        let control = try code("Done/Views/Calendar/Components/CalendarEffortQuickControl.swift")
        let detail = try code("Done/Views/Calendar/CalendarEventDetailView.swift")
        for (signature, source) in [("func handleDragActiveChanged(", glass), ("func commitDrag(", control), ("func commitEffortDrag(", detail)] {
            XCTAssertFalse(try body(of: signature, in: source).contains("UsageProbe."), "\(signature) is a shared commit: it must not count")
        }
        XCTAssertTrue(try body(of: "func handleRelease(", in: control).contains("UsageProbe.use(.eventDetailReflect)"))
        XCTAssertTrue(try body(of: "func handleEnded(", in: glass).contains("onRelease?(finalValue)"), "only .onEnded's handler releases")
        XCTAssertTrue(control.contains("onRelease: handleRelease"), "the control hands the scrubber its release handler")
    }
}

// MARK: - The route jump's page writes

/// The re-appear rewrite needs a finger to have left the route's page first,
/// which a test cannot do on the real view: the decision the view calls is
/// driven here instead. The open-onto-reflection case is also on the real
/// view (`UsageDetailLateWriteTests`).
@MainActor
final class UsageRouteJumpTests: XCTestCase {
    func testTheFirstJumpIsTheEntrysChoiceAndARejumpOnReappearIsNot() {
        let open = DetailPageViewUsage.routeJump(force: true, didHandleInitialJump: false, selected: .overview, target: .reflection)
        XCTAssertEqual(open, .init(runs: true, write: .reflection, reasserted: false))
        XCTAssertTrue(DetailPageViewUsage.isView(page: .reflection, reasserted: open.reasserted), "Log opened it: a view")

        // The user swiped to the overview, opened the chat, came back.
        let reappear = DetailPageViewUsage.routeJump(force: true, didHandleInitialJump: true, selected: .overview, target: .reflection)
        XCTAssertEqual(reappear, .init(runs: true, write: .reflection, reasserted: true))
        XCTAssertFalse(DetailPageViewUsage.isView(page: .reflection, reasserted: reappear.reasserted), "the route re-asserting its page")

        XCTAssertEqual(DetailPageViewUsage.routeJump(force: false, didHandleInitialJump: true, selected: .overview, target: .reflection),
                       .init(runs: false, write: nil, reasserted: false), "an unforced jump after the first does nothing")
        XCTAssertEqual(DetailPageViewUsage.routeJump(force: true, didHandleInitialJump: true, selected: .reflection, target: .reflection).write,
                       nil, "already there: no write, so nothing to mark")
        XCTAssertTrue(DetailPageViewUsage.isView(page: .reflection, reasserted: false), "the user's own swipe")
        XCTAssertFalse(DetailPageViewUsage.isView(page: .overview, reasserted: false))
    }

    /// The view uses the decision rather than restating it.
    func testTheDetailWiresItsRouteJumpThroughTheDecision() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Done/Views/Calendar/CalendarEventDetailView.swift")
        let code = UsageSourceScan.stripCommentsAndStrings(try String(contentsOf: url, encoding: .utf8))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        XCTAssertTrue(code.contains("let plan = DetailPageViewUsage.routeJump(force: force, didHandleInitialJump: didHandleInitialJump, selected: selectedPage, target: target)"))
        XCTAssertTrue(code.contains("usageProgrammaticPageWrite = plan.reasserted selectedPage = page"))
        XCTAssertTrue(code.contains("if DetailPageViewUsage.isView(page: page, reasserted: reasserted) { UsageProbe.view(.eventDetailReflection) }"))
    }
}
