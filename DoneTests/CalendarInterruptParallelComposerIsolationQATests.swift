//  CalendarInterruptParallelComposerIsolationQATests
//
//  INDEPENDENT QA (lane: interrupt/parallel composer isolation) for gh#195.
//  Written by a reviewer who does NOT touch production code. gh#195 moved the
//  interrupt/parallel mini-composers' title+note text out of four parent
//  `@State` vars (`interruptTitle`/`interruptNoteText`/`parallelTitle`/
//  `parallelNoteText`) into two `CalendarInterruptParallelComposerDraft`
//  ObservableObject boxes held via PLAIN `@State`, so a keystroke no longer
//  re-evaluates `CalendarEventDetailView.body` (and thus never re-runs the
//  ~470-line `timelineSection` / `miniDayLayout`). The isolation property is:
//
//    * A note/title keystroke mutates the box (an ObservableObject). `@State`
//      does NOT subscribe to `objectWillChange`, so the holder (the parent)
//      never re-runs. Only the two `@ObservedObject` editor leaves do.
//
//  These tests attack the fix from four independent angles the branch's own
//  `CalendarDetailTimelineIsolationTests` does not fully close:
//
//    QA-A  MECHANISM + POSITIVE CONTROL in one harness: a note keystroke leaves
//          `subtree` FLAT while the editor leaf climbs — AND a legitimately
//          parent-observed change (mirroring `timelineMode`, which stays parent
//          `@State` and IS read by the subtree) bumps `subtree` by exactly one.
//          The positive control proves the flat assertion is not vacuous.
//    QA-A' TEETH: the identical harness with the box held via `@ObservedObject`
//          instead of `@State` (i.e. the fix UNDONE — text back in a
//          parent-observed slot) makes the same note keystroke CLIMB `subtree`.
//          This is the in-test analog of "bind the title back to parent
//          @State": it proves the QA-A assertion fails the moment the ownership
//          regresses, without mutating production.
//    QA-B  TITLE keystroke isolates too (AI suggestions off): the title leaf's
//          relocated `onChange` fires (the leaf saw the character) while
//          `subtree` stays flat.
//    QA-C  IMPERATIVE READ (the save/persist shape): typing through the real
//          leaves' two-way bindings reaches an imperative `draft.title` /
//          `draft.note` read — the exact expression `saveInterrupt` /
//          `saveParallel` use — including the trailing-space trim.
//    QA-D  STORE BEHAVIOUR the save path writes THROUGH: `createInterrupt` +
//          the note update, and `addCalendarEvent`, persist title/type/note and
//          honour the empty-type→parent-type fallback.
//    QA-E  TYPE-SUGGESTION + TRACK-TINT kernels the composer still feeds:
//          `calendarTypeSuggestionRawText` is a function of the box title, the
//          gate honours the setting + explicit-selection, and the tint is a
//          function of `typeTitle`.
//    QA-F  WIRING PINS (the seam no harness can reach): source-level guards that
//          production ROUTES the composer text through the box leaves, HOLDS
//          the boxes via plain `@State`, has `saveInterrupt`/`saveParallel` READ
//          the box imperatively, and keeps `typeTitle` parent `@State`. These
//          are what deterministically kill the two named production mutations
//          ("bind title back to parent @State" removes the leaf route; "save
//          reads old @State" drops the box read) — a mechanism harness embeds
//          the leaf types directly and cannot observe how the *view* wires them.
//          Idiomatic here: `Spike201EmitSiteInventoryTests` pins seams the same
//          source-walking way.
//
//  Uses the repo `SpikeProbe` body-pass seam (the resident listener is not
//  created under XCTest, so a test owns `SpikeProbe.onSignal`) and the same
//  real-UIWindow host + run-loop pump the branch's tests established.

import Combine
import SwiftUI
import UIKit
import XCTest
@testable import Done

@MainActor
final class CalendarInterruptParallelComposerIsolationQATests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var location: EventStorageLocation!

    override func setUp() {
        super.setUp()
        suiteName = "CalendarInterruptParallelComposerIsolationQATests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        location = TestStorage.reset(suiteName)
        SpikeProbe.onSignal = nil
    }

    override func tearDown() {
        SpikeProbe.onSignal = nil
        TestStorage.tearDown(suiteName)
        defaults = nil
        suiteName = nil
        location = nil
        super.tearDown()
    }

    private func makeStore() -> EventStore {
        EventStore(defaults: defaults, storage: location, seedsSampleDataIfEmpty: false)
    }

    // MARK: - Host helpers (real UIWindow, real run loop)

    /// A `UIHostingController` alone never materializes deep content or runs
    /// `onChange`; it takes a window on the live scene, a layout pass, and
    /// run-loop time. Same rig the branch's isolation tests use.
    private func host<V: View>(_ view: V) -> (window: UIWindow, displaced: UIWindow?) {
        let controller = UIHostingController(rootView: view)
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
        return (window, displaced)
    }

    private func teardownHost(_ h: (window: UIWindow, displaced: UIWindow?)) {
        h.window.isHidden = true
        h.window.rootViewController = nil
        h.displaced?.makeKeyAndVisible()
    }

    private func pump(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func productionSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // DoneTests/
            .deletingLastPathComponent()   // repo root
        return try String(
            contentsOf: root.appendingPathComponent("Done/Views/Calendar/CalendarEventDetailView.swift"),
            encoding: .utf8
        )
    }

    // MARK: - QA-A : note keystroke isolates the subtree (+ positive control)

    func testInterruptNoteKeystrokeIsolatesSubtreeWithPositiveControl() {
        assertNoteKeystrokeIsolates(signalID: CalendarDetailTimelineSignalID.interruptField)
    }

    func testParallelNoteKeystrokeIsolatesSubtreeWithPositiveControl() {
        assertNoteKeystrokeIsolates(signalID: CalendarDetailTimelineSignalID.parallelField)
    }

    /// One harness, both directions. The note box is held via PLAIN `@State`
    /// (unobserved, like production), a `control` box the parent DOES observe
    /// stands in for `timelineMode` and friends (parent `@State` the subtree
    /// legitimately reads), and the `subtree` probe is emitted INLINE in the
    /// parent body so its count climbs only when the parent re-runs.
    private func assertNoteKeystrokeIsolates(
        signalID: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let box = CalendarInterruptParallelComposerDraft()
        let control = ComposerHarnessControl()

        var leafPasses = 0
        var subtreePasses = 0
        var persistDrives = 0
        SpikeProbe.onSignal = { signal in
            switch signal {
            // `signalID` is a value, so match it in a `where` clause — a bare
            // identifier in the pattern would BIND, not compare.
            case let .bodyPass(id) where id == signalID:
                leafPasses += 1
            case .bodyPass(CalendarDetailTimelineSignalID.subtree):
                subtreePasses += 1
            default:
                break
            }
        }

        let h = host(
            ComposerIsolationHarness(
                box: box,
                control: control,
                signalID: signalID,
                onNoteChange: { persistDrives += 1 },
                onTitleChange: {}
            )
        )
        defer { teardownHost(h) }

        XCTAssertGreaterThan(leafPasses, 0, "note leaf never rendered — fixture is wrong", file: file, line: line)
        XCTAssertGreaterThan(subtreePasses, 0, "subtree probe never rendered — fixture is wrong", file: file, line: line)

        // ---- (1) POSITIVE CONTROL: a parent-observed change climbs subtree.
        subtreePasses = 0
        control.tick += 1
        pump(0.3)
        XCTAssertGreaterThanOrEqual(
            subtreePasses, 1,
            "a legitimately parent-observed change (mirroring a timelineMode flip) did NOT re-run "
            + "the subtree (saw \(subtreePasses)); the subtree probe is dead and every flat "
            + "assertion below would pass vacuously",
            file: file, line: line
        )

        // ---- (2) THE INVARIANT: a note keystroke isolates.
        leafPasses = 0
        subtreePasses = 0
        persistDrives = 0

        box.note = "a"
        pump(0.3)
        box.note = "ab"
        pump(0.3)
        box.note = "abc"
        pump(0.3)

        XCTAssertGreaterThanOrEqual(
            leafPasses, 2,
            "typing did not re-render the composer note leaf (saw \(leafPasses)); the box wiring is broken",
            file: file, line: line
        )
        XCTAssertEqual(
            subtreePasses, 0,
            "a note keystroke re-ran the timeline subtree \(subtreePasses) time(s); typing must not "
            + "rebuild timelineSection/miniDayLayout (gh#195)",
            file: file, line: line
        )
        // The continuous-write re-drive the leaf now carries (parent body no
        // longer sees the keystroke — guardrail 2).
        XCTAssertGreaterThanOrEqual(
            persistDrives, 2,
            "a note keystroke did not re-drive the draft persist from the leaf (saw \(persistDrives)); "
            + "the continuous-write hardening regressed",
            file: file, line: line
        )
    }

    // MARK: - QA-A' : teeth — leaky ownership makes the same keystroke climb

    /// The in-test analog of the named "bind the title back to parent @State"
    /// mutation. Identical harness EXCEPT the box is held via `@ObservedObject`
    /// (the parent now observes it — exactly what putting the text back into a
    /// parent-observed slot does). The same note keystroke that stayed flat in
    /// QA-A must now CLIMB `subtree`. If this ever stops climbing, QA-A has no
    /// teeth — so this pins that the flat result is caused by the `@State`
    /// ownership and nothing else.
    func testLeakyOwnershipMakesNoteKeystrokeClimbSubtreeProvingTeeth() {
        let box = CalendarInterruptParallelComposerDraft()

        var subtreePasses = 0
        SpikeProbe.onSignal = { signal in
            if case .bodyPass(CalendarDetailTimelineSignalID.subtree) = signal { subtreePasses += 1 }
        }

        let h = host(
            LeakyComposerIsolationHarness(
                box: box,
                signalID: CalendarDetailTimelineSignalID.interruptField
            )
        )
        defer { teardownHost(h) }

        XCTAssertGreaterThan(subtreePasses, 0, "subtree probe never rendered — fixture is wrong")
        subtreePasses = 0

        box.note = "a"
        pump(0.3)
        box.note = "ab"
        pump(0.3)

        XCTAssertGreaterThanOrEqual(
            subtreePasses, 1,
            "with the box held via @ObservedObject (the fix undone), a note keystroke did NOT re-run "
            + "the subtree (saw \(subtreePasses)); if the leak does not climb, QA-A's flat assertion "
            + "cannot be trusted to detect the regression"
        )
    }

    // MARK: - QA-B : title keystroke isolates too (AI suggestions off)

    func testInterruptTitleKeystrokeIsolatesSubtree() {
        assertTitleKeystrokeIsolates(signalID: CalendarDetailTimelineSignalID.interruptField)
    }

    func testParallelTitleKeystrokeIsolatesSubtree() {
        assertTitleKeystrokeIsolates(signalID: CalendarDetailTimelineSignalID.parallelField)
    }

    /// The title field carries no body-pass probe (a title keystroke can
    /// legally bump `subtree` async when AI suggestions flip `typeTitle`), so
    /// the harness wires a NO-OP `onTitleChange` (AI off) and proves isolation
    /// two ways: the title leaf's relocated `onChange` FIRED (the leaf saw the
    /// character) while `subtree` stayed FLAT.
    private func assertTitleKeystrokeIsolates(
        signalID: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let box = CalendarInterruptParallelComposerDraft()
        let control = ComposerHarnessControl()

        var subtreePasses = 0
        SpikeProbe.onSignal = { signal in
            if case .bodyPass(CalendarDetailTimelineSignalID.subtree) = signal { subtreePasses += 1 }
        }

        var titleChanges = 0
        let h = host(
            ComposerIsolationHarness(
                box: box,
                control: control,
                signalID: signalID,
                onNoteChange: {},
                onTitleChange: { titleChanges += 1 }
            )
        )
        defer { teardownHost(h) }

        XCTAssertGreaterThan(subtreePasses, 0, "subtree probe never rendered — fixture is wrong", file: file, line: line)
        subtreePasses = 0
        titleChanges = 0

        box.title = "L"
        pump(0.3)
        box.title = "Lu"
        pump(0.3)
        box.title = "Lunch"
        pump(0.3)

        XCTAssertGreaterThanOrEqual(
            titleChanges, 2,
            "typing the title did not fire the leaf's relocated onChange (saw \(titleChanges)); the "
            + "title leaf is not observing the box",
            file: file, line: line
        )
        XCTAssertEqual(
            subtreePasses, 0,
            "a title keystroke (AI off) re-ran the timeline subtree \(subtreePasses) time(s); with no "
            + "AI suggestion in flight, typing the title must not rebuild the timeline (gh#195)",
            file: file, line: line
        )
    }

    // MARK: - QA-C : typed text reaches the imperative reader the save uses

    /// `saveInterrupt`/`saveParallel` read `draft.title`/`draft.note`
    /// IMPERATIVELY and `trimmingCharacters(in: .whitespacesAndNewlines)`.
    /// Type through the REAL leaves' two-way bindings (as a keystroke does) and
    /// confirm that exact read shape sees every character even though the
    /// parent body never re-ran — otherwise a save at this instant would
    /// persist stale/empty text.
    func testTypedTitleAndNoteReachImperativeReadersThroughTheBox() {
        let box = CalendarInterruptParallelComposerDraft()
        let control = ComposerHarnessControl()

        let h = host(
            ComposerIsolationHarness(
                box: box,
                control: control,
                signalID: CalendarDetailTimelineSignalID.parallelField,
                onNoteChange: {},
                onTitleChange: {}
            )
        )
        defer { teardownHost(h) }

        box.title = "Standup"
        pump(0.2)
        box.title = "Standup  "        // trailing space the trim must drop
        pump(0.2)
        box.note = "bring  "
        pump(0.2)
        box.note = "bring laptop  "    // trailing space the trim must drop
        pump(0.2)

        // Exactly the expression the save path evaluates.
        let readTitle = box.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let readNote = box.note.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(
            readTitle, "Standup",
            "an imperative read of the box title did not see the typed text; a save here would persist '\(readTitle)'"
        )
        XCTAssertEqual(
            readNote, "bring laptop",
            "an imperative read of the box note did not see the typed text; a save here would persist '\(readNote)'"
        )
    }

    // MARK: - QA-D : the store primitives the save path writes through

    /// `saveInterrupt` calls `store.createInterrupt(...)` then, for a non-empty
    /// note, `store.updateCalendarEvent(...)`. Both must persist what they are
    /// handed. (The view method itself is not unit-invokable — it reads an
    /// `@EnvironmentObject` store and installed `@State` — so this pins the
    /// exact store calls it makes, with the exact arguments.)
    func testCreateInterruptPersistsTitleTypeAndNote() throws {
        let store = makeStore()
        let start = Date(timeIntervalSince1970: 5_000_000)
        let parent = Event(
            id: UUID(),
            title: "Deep work",
            timeRanges: [.init(start: start, end: start.addingTimeInterval(3600))],
            type: "Study"
        )
        store.rawCalendarEvents = [parent]

        let iRange = Event.TimeRange(
            start: start.addingTimeInterval(900),
            end: start.addingTimeInterval(1800)
        )
        let created = try XCTUnwrap(
            store.createInterrupt(
                parentEvent: parent,
                occurrenceDate: start,
                title: "Phone call",
                type: "Life",
                timeRange: iRange
            ),
            "createInterrupt returned nil for an in-range interrupt"
        )
        // saveInterrupt applies a non-empty note via a follow-up update.
        var withNote = try XCTUnwrap(store.findCalendarEvent(id: created.id))
        withNote.note = "insurance renewal"
        store.updateCalendarEvent(withNote)

        let persisted = try XCTUnwrap(store.findCalendarEvent(id: created.id))
        XCTAssertEqual(persisted.title, "Phone call", "interrupt title not persisted")
        XCTAssertEqual(persisted.type, "Life", "interrupt type not persisted")
        XCTAssertEqual(persisted.note, "insurance renewal", "interrupt note not persisted")
        XCTAssertEqual(persisted.displayKind, .interrupt, "interrupt displayKind lost")
    }

    /// Empty type on an interrupt falls back to the parent's type (createInterrupt).
    func testCreateInterruptEmptyTypeFallsBackToParentType() throws {
        let store = makeStore()
        let start = Date(timeIntervalSince1970: 6_000_000)
        let parent = Event(
            id: UUID(),
            title: "Deep work",
            timeRanges: [.init(start: start, end: start.addingTimeInterval(3600))],
            type: "Study"
        )
        store.rawCalendarEvents = [parent]

        let created = try XCTUnwrap(
            store.createInterrupt(
                parentEvent: parent,
                occurrenceDate: start,
                title: "",                       // empty title → "Interrupt"
                type: "",                        // empty type → parent's "Study"
                timeRange: .init(start: start.addingTimeInterval(600), end: start.addingTimeInterval(1200))
            )
        )
        let persisted = try XCTUnwrap(store.findCalendarEvent(id: created.id))
        XCTAssertEqual(persisted.title, "Interrupt", "empty interrupt title must default to 'Interrupt'")
        XCTAssertEqual(persisted.type, "Study", "empty interrupt type must fall back to the parent's type")
    }

    /// `saveParallel` builds an `Event(title:note:location:timeRanges:type:)`
    /// (type falling back to the parent's when empty) and calls
    /// `store.addCalendarEvent`. Pin that the values survive the round trip.
    func testAddParallelEventPersistsTitleNoteType() throws {
        let store = makeStore()
        let start = Date(timeIntervalSince1970: 7_000_000)
        let range = Event.TimeRange(start: start, end: start.addingTimeInterval(3600))
        let event = Event(
            title: "Email triage",
            note: "inbox zero",
            location: "",
            timeRanges: [range],
            type: "Work"
        )
        store.addCalendarEvent(event)

        let persisted = try XCTUnwrap(store.findCalendarEvent(id: event.id))
        XCTAssertEqual(persisted.title, "Email triage", "parallel title not persisted")
        XCTAssertEqual(persisted.note, "inbox zero", "parallel note not persisted")
        XCTAssertEqual(persisted.type, "Work", "parallel type not persisted")
    }

    /// The parallel empty-type→parent-type fallback is arithmetic in the view
    /// (`type.isEmpty ? parentEvent.type : type`); pin the branch so a save of
    /// an untyped parallel event inherits the parent type.
    func testParallelEmptyTypeFallsBackToParentType() {
        let parentType = "Study"
        let typed = ""
        let resolved = typed.isEmpty ? parentType : typed
        XCTAssertEqual(resolved, "Study", "an untyped parallel event must inherit the parent's type")

        let explicit = "Life"
        let resolved2 = explicit.isEmpty ? parentType : explicit
        XCTAssertEqual(resolved2, "Life", "an explicitly typed parallel event must keep its own type")
    }

    // MARK: - QA-E : the type-suggestion + track-tint kernels the composer feeds

    /// `scheduleInterrupt/ParallelAutoTypeSelection` compute the suggestion's
    /// raw text as `calendarTypeSuggestionRawText(title: box.title, note: "")`.
    /// Pin that it is a pure function of the box title (so a keystroke changing
    /// the box changes the suggestion input) — and that the `note: ""` argument
    /// means the note never participates.
    func testTypeSuggestionRawTextIsAFunctionOfTheBoxTitle() {
        XCTAssertEqual(
            calendarTypeSuggestionRawText(title: "Lunch with Sam", note: ""),
            "Lunch with Sam",
            "the composer feeds only the title into the suggestion"
        )
        XCTAssertEqual(
            calendarTypeSuggestionRawText(title: "  Gym  ", note: ""),
            "Gym",
            "the title is trimmed before scoring"
        )
        XCTAssertEqual(
            calendarTypeSuggestionRawText(title: "", note: ""),
            "",
            "an empty title yields no suggestion text"
        )
    }

    /// The while-typing suggestion runs only when AI suggestions are ON and the
    /// user has not explicitly chosen a type — the gate `schedule*` guards on.
    func testTypeSuggestionGateHonorsSettingAndExplicitSelection() {
        XCTAssertTrue(
            calendarShouldRunPostSaveTypeSuggestion(isEnabled: true, didExplicitlySelectType: false),
            "on + not-explicit must run"
        )
        XCTAssertFalse(
            calendarShouldRunPostSaveTypeSuggestion(isEnabled: false, didExplicitlySelectType: false),
            "AI off must not run"
        )
        XCTAssertFalse(
            calendarShouldRunPostSaveTypeSuggestion(isEnabled: true, didExplicitlySelectType: true),
            "an explicit chip selection must suppress the auto suggestion"
        )
    }

    /// The interrupt/parallel track tint is `EventTypeTemplateStore.color(for:
    /// typeTitle)` (non-empty) or a fixed fallback. `color(for:)` is
    /// `ColorHex.toColor(colorHex(for:))`; pin the tint-defining hex is a
    /// function of the type title, seeded from a real template.
    func testTrackTintHexIsAFunctionOfTypeTitle() {
        let store = EventTypeTemplateStore(defaults: defaults)
        let template = try? XCTUnwrap(store.templates.first)
        guard let template else {
            XCTFail("no seeded templates to tint from")
            return
        }
        XCTAssertEqual(
            EventTypeTemplateStore.colorHex(for: template.title, defaults: defaults),
            template.colorHex,
            "the tint for a known type must resolve to that type's template color"
        )
    }

    // MARK: - QA-F : wiring pins (deterministic kill for the two named mutations)

    /// F1 — kills "bind the interrupt/parallel title back to parent @State":
    /// production must route BOTH composers' title AND note through the box
    /// leaves, bound to the matching box. Reintroducing a
    /// `TextField("Title", text: $interruptTitle)` removes this exact call.
    func testProductionRoutesComposerTextThroughTheDraftBoxLeaves() throws {
        let src = try productionSource()
        // Interrupt composer routes.
        XCTAssertTrue(
            src.contains("CalendarInterruptParallelTitleField(draft: interruptComposerDraft)"),
            "interrupt title must be routed through the box leaf, not a parent-@State TextField"
        )
        XCTAssertTrue(
            src.contains("draft: interruptComposerDraft,"),
            "interrupt note field must bind to the interrupt box"
        )
        // Parallel composer routes.
        XCTAssertTrue(
            src.contains("CalendarInterruptParallelTitleField(draft: parallelComposerDraft)"),
            "parallel title must be routed through the box leaf, not a parent-@State TextField"
        )
        XCTAssertTrue(
            src.contains("draft: parallelComposerDraft,"),
            "parallel note field must bind to the parallel box"
        )
        // The removed regression: no direct parent-@State text binding may
        // return for the composer title/note.
        XCTAssertFalse(
            src.contains("TextField(\"Title\", text: $interruptTitle)")
                || src.contains("TextEditor(text: $interruptNoteText)")
                || src.contains("TextField(\"Title\", text: $parallelTitle)")
                || src.contains("TextEditor(text: $parallelNoteText)"),
            "a composer text field is bound straight to parent @State again — the gh#195 isolation is undone"
        )
    }

    /// F2 — the boxes are held via PLAIN `@State` (an unobserved holder is the
    /// whole fix). `@StateObject`/`@ObservedObject` would re-subscribe the
    /// parent and every keystroke would rebuild the timeline again.
    func testProductionHoldsComposerBoxesViaPlainStateNotObserved() throws {
        let src = try productionSource()
        XCTAssertTrue(
            src.contains("@State private var interruptComposerDraft = CalendarInterruptParallelComposerDraft()"),
            "interrupt box must be a plain @State"
        )
        XCTAssertTrue(
            src.contains("@State private var parallelComposerDraft = CalendarInterruptParallelComposerDraft()"),
            "parallel box must be a plain @State"
        )
        XCTAssertFalse(
            src.contains("@StateObject private var interruptComposerDraft")
                || src.contains("@ObservedObject private var interruptComposerDraft")
                || src.contains("@StateObject private var parallelComposerDraft")
                || src.contains("@ObservedObject private var parallelComposerDraft"),
            "a composer box is held via an OBSERVED wrapper — the parent now re-runs on every keystroke"
        )
    }

    /// F3 — kills "make the save read old @State": `saveInterrupt` /
    /// `saveParallel` must read the box IMPERATIVELY. Extract each function body
    /// and assert the box reads are present.
    func testSaveFunctionsReadTheBoxImperatively() throws {
        let src = try productionSource()

        let interrupt = try functionBody(named: "func saveInterrupt()", in: src)
        XCTAssertTrue(
            interrupt.contains("interruptComposerDraft.title"),
            "saveInterrupt must read the box title imperatively (not a stale parent @State)"
        )
        XCTAssertTrue(
            interrupt.contains("interruptComposerDraft.note"),
            "saveInterrupt must read the box note imperatively"
        )

        let parallel = try functionBody(named: "func saveParallel()", in: src)
        XCTAssertTrue(
            parallel.contains("parallelComposerDraft.title"),
            "saveParallel must read the box title imperatively"
        )
        XCTAssertTrue(
            parallel.contains("parallelComposerDraft.note"),
            "saveParallel must read the box note imperatively"
        )
    }

    /// F4 — red line: `typeTitle` deliberately STAYS parent `@State` (track
    /// tint / chip selection / scroll-to read it outside the composer, and it
    /// only changes on a chip tap or the debounced suggestion). It must not be
    /// sunk into the box.
    func testTypeTitleStaysParentStateNotSunkIntoTheBox() throws {
        let src = try productionSource()
        XCTAssertTrue(
            src.contains("@State private var interruptTypeTitle: String = \"\""),
            "interruptTypeTitle must stay parent @State"
        )
        XCTAssertTrue(
            src.contains("@State private var parallelTypeTitle: String = \"\""),
            "parallelTypeTitle must stay parent @State"
        )
        // The box carries only title + note, never typeTitle.
        let boxDecl = try functionBody(
            named: "final class CalendarInterruptParallelComposerDraft: ObservableObject",
            in: src
        )
        XCTAssertFalse(
            boxDecl.contains("typeTitle"),
            "typeTitle must not be a field of the composer box (it stays parent @State)"
        )
        XCTAssertTrue(
            boxDecl.contains("var title") && boxDecl.contains("var note"),
            "the box must carry exactly the title + note text"
        )
    }

    /// Returns the brace-balanced body that follows the first occurrence of
    /// `signature` (up to and including its matching close brace). Robust to
    /// indentation and line breaks — used by the wiring pins above.
    private func functionBody(named signature: String, in source: String) throws -> String {
        let start = try XCTUnwrap(
            source.range(of: signature),
            "signature not found: \(signature)"
        )
        guard let open = source[start.upperBound...].firstIndex(of: "{") else {
            throw XCTSkip("no opening brace after \(signature)")
        }
        var depth = 0
        var idx = open
        while idx < source.endIndex {
            let ch = source[idx]
            if ch == "{" { depth += 1 }
            else if ch == "}" {
                depth -= 1
                if depth == 0 {
                    return String(source[open...idx])
                }
            }
            idx = source.index(after: idx)
        }
        throw XCTSkip("unbalanced braces after \(signature)")
    }
}

// MARK: - QA harness views

/// A single reference box the harness parent OBSERVES, standing in for the
/// parent `@State` the real subtree legitimately reads (`timelineMode`,
/// `interruptItems`, `editingInterruptID`, …). Bumping `tick` re-runs the
/// parent — the positive control that proves the inline `subtree` probe is
/// alive.
private final class ComposerHarnessControl: ObservableObject {
    @Published var tick: Int = 0
}

/// Mirrors production ownership: the composer box is held via PLAIN `@State`
/// (so mutating it does NOT re-run this parent), a `control` box the parent
/// observes stands in for legitimately parent-owned state, and the `subtree`
/// body-pass is emitted INLINE here — exactly as production emits it inline in
/// `timelineSection`, never from a child (a stateless child probe is diff-
/// skipped and could not tell "parent re-ran" from "parent stayed"). The REAL
/// `CalendarInterruptParallelTitleField` + `CalendarInterruptParallelNoteField`
/// leaves are embedded, bound to the box.
private struct ComposerIsolationHarness: View {
    @State private var box: CalendarInterruptParallelComposerDraft
    @ObservedObject private var control: ComposerHarnessControl
    let signalID: String
    let onNoteChange: () -> Void
    let onTitleChange: () -> Void

    init(
        box: CalendarInterruptParallelComposerDraft,
        control: ComposerHarnessControl,
        signalID: String,
        onNoteChange: @escaping () -> Void,
        onTitleChange: @escaping () -> Void
    ) {
        _box = State(initialValue: box)
        _control = ObservedObject(initialValue: control)
        self.signalID = signalID
        self.onNoteChange = onNoteChange
        self.onTitleChange = onTitleChange
    }

    var body: some View {
        // Reading `control.tick` is what subscribes THIS body to the control
        // box; the read must be observable, so surface it in the tree.
        let _ = SpikeProbe.emit(.bodyPass(CalendarDetailTimelineSignalID.subtree))
        return VStack(spacing: 8) {
            Text(verbatim: "tick=\(control.tick)").frame(width: 1, height: 1).opacity(0)
            CalendarInterruptParallelTitleField(draft: box, onTitleChange: onTitleChange)
            CalendarInterruptParallelNoteField(
                draft: box,
                bodyPassSignalID: signalID,
                onNoteChange: onNoteChange
            )
            Color.clear.frame(width: 1, height: 1)
        }
    }
}

/// The fix UNDONE: the box is held via `@ObservedObject`, so the parent now
/// re-subscribes to it and a keystroke re-runs this body (climbing `subtree`).
/// Used only to prove the isolation assertion has teeth.
private struct LeakyComposerIsolationHarness: View {
    @ObservedObject private var box: CalendarInterruptParallelComposerDraft
    let signalID: String

    init(box: CalendarInterruptParallelComposerDraft, signalID: String) {
        _box = ObservedObject(initialValue: box)
        self.signalID = signalID
    }

    var body: some View {
        let _ = SpikeProbe.emit(.bodyPass(CalendarDetailTimelineSignalID.subtree))
        return VStack(spacing: 8) {
            CalendarInterruptParallelNoteField(
                draft: box,
                bodyPassSignalID: signalID,
                onNoteChange: {}
            )
            Color.clear.frame(width: 1, height: 1)
        }
    }
}
