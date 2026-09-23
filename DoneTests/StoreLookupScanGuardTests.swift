//
//  StoreLookupScanGuardTests.swift
//  DoneTests
//
//  gh#213 slice 2. Two instruments, one campaign.
//
//  INSTRUMENT 1 — the anti-recurrence guard. Slice 1 put id→index maps
//  behind `EventStore.findCalendarEvent(id:)` / `logRecordIndex(id:)` /
//  `feedbackRecordIndex(id:)`; slice 2 converted the last 22 bare by-id
//  scans. The census that found them was a grep, and the root cause the
//  canvasRenderable audit named — "filter added after consumers, no sweep"
//  — applies verbatim: nothing stops the 23rd site from being written next
//  week. So the census IS the test now: the scan below runs the same
//  pattern over every `.swift` file under `Done/` and fails, naming
//  file:line, on any match that is not the allowlisted doc-comment line.
//
//  It is a SOURCE scan, declared weaker than a behavioural test in the
//  `Spike201EmitSiteInventoryTests` idiom, with that family's limits:
//  it is line-shaped (a scan split across lines evades it — so does it
//  evade the census grep this mirrors, which is the honest baseline), and
//  it cannot prove the helpers are CORRECT (slice 1's
//  `EventStoreLookupIndexTests` does that). It proves recurrence cannot
//  land silently.
//
//  LIVENESS: a scanner that finds nothing must prove it can find something.
//  Two proofs here, one per failure mode: the allowlisted EventStore doc
//  comment must be FOUND (file enumeration reached the real tree), and the
//  embedded positive-control fixtures must MATCH (the regex still
//  recognizes every surface spelling: `first(where:`, `firstIndex(where:`,
//  trailing-closure `first {`, and all three arrays).
//
//  INSTRUMENT 2 — the drawer hoist pin (same census family, from the
//  audits). `TodoStackDrawer`'s un-hoisted body evaluated `orderedTodos`
//  three times and `store.datelessTodos` twice more per body pass — five
//  full `rawCalendarEvents` filters per frame at up to 120Hz during a
//  chrome drag. The body now hoists one `let ordered = orderedTodos`.
//  The pin is the `onDetailBodyPass` lesson applied again: an INVARIANT
//  (`computations <= passes + 1`) counted through per-instance seams, not
//  a constant tied to how many passes SwiftUI decides to run. The `+ 1`
//  is `resetForOpen()`'s one-shot resurface scan on `.onAppear`.
//

import XCTest
import SwiftUI
import UIKit
@testable import Done

// MARK: - Instrument 1: the anti-recurrence guard

final class StoreLookupScanGuardTests: XCTestCase {

    /// `#filePath` is this file's location at COMPILE time, which is the
    /// checkout the test binary was built from. Two directories up is the
    /// repo root. (The `Spike201EmitSiteInventoryTests` idiom.)
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // DoneTests/
            .deletingLastPathComponent()   // repo root
    }

    /// The census pattern from gh#213, widened to the two sibling record
    /// arrays that share the same index helpers. This is the exact shape of
    /// the grep the campaign ran:
    ///   (array)\.(first|firstIndex|last|lastIndex)(\(where: )? *\{ *\$0\.id ==
    private let censusPattern =
        #"(rawCalendarEvents|calendarEventLogRecords|calendarEventFeedbackRecords)\.(first|firstIndex|last|lastIndex)(\(where: )? *\{ *\$0\.id =="#

    /// The complete allowlist. One entry: the doc comment on
    /// `EventStore.calendarEventIndex(id:)` that states the helper's
    /// contract BY QUOTING the scan it replaced. It must be a comment line
    /// (`assertMatchIsAComment` below) in exactly this file. Growing this
    /// list is a deliberate act with a diff in this test — which is the
    /// point.
    private let allowlist: [(fileSuffix: String, fragment: String)] = [
        ("Done/Models/EventStore.swift",
         #"Same answer as `rawCalendarEvents.firstIndex(where: { $0.id == id })`."#)
    ]

    /// One fixture per surface spelling the pattern must keep recognizing.
    /// These live INSIDE the test bundle, which the scan does not walk, so
    /// they prove the regex without polluting the census.
    private let positiveControls = [
        #"guard let event = store.rawCalendarEvents.first(where: { $0.id == id }) else { return }"#,
        #"if let idx = store.rawCalendarEvents.firstIndex(where: { $0.id == eventID }) {"#,
        #"let ghost = rawCalendarEvents.last { $0.id == id }"#,
        #"if let local = store.calendarEventLogRecords.first(where: { $0.id == key }) {"#,
        #"let stale = calendarEventFeedbackRecords.firstIndex(where: { $0.id == key })"#
    ]

    private struct Match {
        let relativePath: String
        let lineNumber: Int
        let line: String
    }

    private func scanProductionSources() throws -> (matches: [Match], filesScanned: Int) {
        let sourceRoot = repoRoot.appendingPathComponent("Done")
        let regex = try NSRegularExpression(pattern: censusPattern)
        var matches: [Match] = []
        var filesScanned = 0
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(at: sourceRoot, includingPropertiesForKeys: nil),
            "could not enumerate \(sourceRoot.path)"
        )
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            filesScanned += 1
            let source = try String(contentsOf: url, encoding: .utf8)
            let lines = source.components(separatedBy: "\n")
            let relative = url.path.replacingOccurrences(of: repoRoot.path + "/", with: "")
            for (index, line) in lines.enumerated() {
                let range = NSRange(line.startIndex..., in: line)
                if regex.firstMatch(in: line, range: range) != nil {
                    matches.append(Match(relativePath: relative, lineNumber: index + 1, line: line))
                }
            }
        }
        return (matches, filesScanned)
    }

    private func isAllowlisted(_ match: Match) -> Bool {
        allowlist.contains { entry in
            match.relativePath.hasSuffix(entry.fileSuffix) && match.line.contains(entry.fragment)
        }
    }

    /// THE guard. Every match must be an allowlisted doc-comment line;
    /// anything else is a new bare by-id scan and fails HERE, by file:line,
    /// before it can start the drift the canvasRenderable audit paid 11
    /// sites to stop.
    func testNoBareByIDScanOutsideTheAllowlist() throws {
        let (matches, filesScanned) = try scanProductionSources()

        // Enumeration-liveness floor: the app tree is far bigger than this.
        // A broken enumerator that walks nothing must not pass vacuously.
        XCTAssertGreaterThan(filesScanned, 50,
                             "only \(filesScanned) Swift files scanned under Done/ — the walk "
                             + "is broken, not the tree clean")

        let violations = matches.filter { !isAllowlisted($0) }
        XCTAssertTrue(
            violations.isEmpty,
            "new bare by-id scan(s) — use store.findCalendarEvent(id:) / findLogRecord(id:) / "
            + "findFeedbackRecord(id:) or the index variants (gh#213):\n"
            + violations.map { "  \($0.relativePath):\($0.lineNumber): \($0.line.trimmingCharacters(in: .whitespaces))" }
                        .joined(separator: "\n")
        )

        // Scanner liveness, proof 1: the walk found the known allowlist line
        // EXACTLY once each. Zero means the scan lost the file (or the doc
        // comment was deleted — update the allowlist in the same commit).
        for entry in allowlist {
            let hits = matches.filter {
                $0.relativePath.hasSuffix(entry.fileSuffix) && $0.line.contains(entry.fragment)
            }
            XCTAssertEqual(hits.count, 1,
                           "allowlist entry not found exactly once (found \(hits.count)): "
                           + "\(entry.fileSuffix) — \(entry.fragment)")
            // The allowlist licenses DOCUMENTATION, never code.
            for hit in hits {
                XCTAssertTrue(hit.line.trimmingCharacters(in: .whitespaces).hasPrefix("//"),
                              "allowlisted line is not a comment: \(hit.relativePath):\(hit.lineNumber)")
            }
        }
    }

    /// Scanner liveness, proof 2: the regex recognizes every surface
    /// spelling of the scan it polices. A pattern edit that quietly stops
    /// matching `first {` (trailing closure) or a sibling array dies here,
    /// not in production drift.
    func testCensusPatternMatchesEverySurfaceSpelling() throws {
        let regex = try NSRegularExpression(pattern: censusPattern)
        for control in positiveControls {
            let range = NSRange(control.startIndex..., in: control)
            XCTAssertNotNil(regex.firstMatch(in: control, range: range),
                            "census pattern went blind to: \(control)")
        }
        // And a negative control, so the pattern cannot degrade into
        // matching everything: a lookup through the blessed helper.
        let blessed = #"guard let event = store.findCalendarEvent(id: id) else { return }"#
        let blessedRange = NSRange(blessed.startIndex..., in: blessed)
        XCTAssertNil(regex.firstMatch(in: blessed, range: blessedRange),
                     "census pattern matches the helper it exists to steer people toward")
    }
}

// MARK: - Instrument 2: the drawer hoist pin

@MainActor
final class TodoStackDrawerHoistTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var location: EventStorageLocation!

    override func setUp() {
        super.setUp()
        suiteName = "TodoStackDrawerHoistTests-\(UUID().uuidString)"
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

    private func makeStore() -> EventStore {
        EventStore(defaults: defaults, storage: location, seedsSampleDataIfEmpty: false)
    }

    /// A drawer resident: dateless, unabsorbed, not done (`isStackTodo`).
    private func stackTodo(_ title: String, deadline: Date? = nil) -> Event {
        var todo = Event(id: UUID(), title: title, timeRanges: [], type: "Study")
        todo.kind = .todo
        todo.deadline = deadline
        return todo
    }

    /// Put the drawer on screen for real — window, layout pass, run-loop
    /// turn — for the same reason `EventStoreLookupIndexTests` hosts the
    /// detail view: a hosting controller that never materializes the card
    /// list measures only part of the body.
    private func renderDrawer(store: EventStore) -> (window: UIWindow, displaced: UIWindow?) {
        let controller = UIHostingController(
            rootView: TodoStackDrawer(isPresented: .constant(true))
                .environmentObject(store)
                .environmentObject(OrientationManager(observeNotifications: false))
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
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        controller.view.layoutIfNeeded()
        return (window, displaced)
    }

    private func teardownHost(_ host: (window: UIWindow, displaced: UIWindow?)) {
        host.window.isHidden = true
        host.window.rootViewController = nil
        host.displaced?.makeKeyAndVisible()
    }

    /// Positive control for the harness: the card list's `ScrollView` must
    /// exist in UIKit, or the counts below measured a body that never built
    /// its expensive branch. Written against the UIKit base class, not the
    /// private SwiftUI subclass name.
    private func assertCardListMaterialized(
        _ window: UIWindow,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var sawScrollView = false
        func walk(_ view: UIView) {
            if view is UIScrollView { sawScrollView = true }
            view.subviews.forEach(walk)
        }
        walk(window)
        XCTAssertTrue(sawScrollView,
                      "the drawer's card list never materialized — the pass count below is "
                      + "measuring an empty shell",
                      file: file, line: line)
    }

    /// The hoist, and the test that dies if it is reverted.
    ///
    /// `computations <= passes + 1`: the body's single hoisted
    /// `orderedTodos` read costs one `datelessTodos` filter per pass, and
    /// `.onAppear`'s `resetForOpen()` resurface scan costs the one-shot
    /// `+ 1`. Un-hoisted, the body cost FIVE per pass (three `orderedTodos`
    /// reads, two raw header reads) — `5p + 1 > p + 1` for every `p >= 1`,
    /// so any pass count SwiftUI picks still fails a revert. Un-hoisting
    /// only the header (`3p + 1`) cannot pass either.
    func testDrawerBodyRunsOneStackFilterPerPassPlusTheOpenScan() {
        let store = makeStore()
        let soon = Date().addingTimeInterval(3600)
        store.rawCalendarEvents = [
            stackTodo("read"), stackTodo("call back", deadline: soon), stackTodo("pack")
        ]
        XCTAssertEqual(store.datelessTodos.count, 3, "fixture: all three must live in the stack")

        var computations = 0
        var passes = 0
        store.onDatelessTodosComputed = { computations += 1 }
        store.onTodoStackBodyPass = { passes += 1 }
        defer {
            store.onDatelessTodosComputed = nil
            store.onTodoStackBodyPass = nil
        }

        let host = renderDrawer(store: store)
        defer { teardownHost(host) }
        assertCardListMaterialized(host.window)

        XCTAssertGreaterThan(passes, 0,
                             "the render never evaluated the drawer body — the fixture is "
                             + "wrong, not the code")
        XCTAssertGreaterThan(computations, 0,
                             "the render never computed the stack — the fixture is wrong, "
                             + "not the code")
        XCTAssertLessThanOrEqual(
            computations, passes + 1,
            "one drawer body pass must run at most ONE datelessTodos filter (plus the "
            + "one-shot onAppear resurface scan), not five (gh#213 slice 2): "
            + "\(computations) computations across \(passes) passes"
        )
    }

    /// Same invariant on the empty-state branch — the branch predicate is
    /// the hoisted value too, so an empty drawer must not re-derive the
    /// stack to decide it is empty.
    func testEmptyDrawerHoldsTheSameBound() {
        let store = makeStore()
        XCTAssertTrue(store.datelessTodos.isEmpty, "fixture: the stack must start empty")

        var computations = 0
        var passes = 0
        store.onDatelessTodosComputed = { computations += 1 }
        store.onTodoStackBodyPass = { passes += 1 }
        defer {
            store.onDatelessTodosComputed = nil
            store.onTodoStackBodyPass = nil
        }

        let host = renderDrawer(store: store)
        defer { teardownHost(host) }

        XCTAssertGreaterThan(passes, 0, "the render never evaluated the drawer body")
        XCTAssertLessThanOrEqual(
            computations, passes + 1,
            "an EMPTY drawer must not pay extra filters to learn it is empty: "
            + "\(computations) computations across \(passes) passes"
        )
    }
}
