//
//  CalendarQuickTagIntentTests.swift
//  DoneTests
//
//  gh#216: the detail screen's quick tag pickers used to compute the whole
//  next tag set from the Button's RENDER-TIME `selection` snapshot and write
//  it verbatim (`var next = selection` → old `applyQuickTags` →
//  `record.emotions = Array(next).sorted()`), so any store change that
//  landed between the last body pass and the tap — an agent write, a sync
//  round-trip, CalendarEventChatView — was silently overwritten. The fix
//  expresses the tap as USER INTENT (tag id, targetSelected judged from
//  what was rendered) and `EventStore.applyQuickTagIntent` re-reads the
//  current set at tap time, applying only that single-tag delta.
//
//  These tests drive `EventStore.applyQuickTagIntent` — the real
//  production handler; the Button's action is a one-expression forward,
//  `onToggle(tag.id, !selected)` → this method. The handler lives on the
//  store rather than the view for the same reason
//  `calendarEffortDragShouldCommit` does (gh#162 W1): calling a method
//  that reads `@EnvironmentObject var store` on a freshly constructed
//  CalendarEventDetailView crashes under test. A consequence these tests
//  lean on deliberately: the seam's signature only ADMITS intent — there
//  is no parameter through which a render-time set could reach the write,
//  so a true revert to the old shape cannot even compile against
//  `testExternalTagWriteBetweenRenderAndTapSurvivesTheTap`. The mutation
//  experiments recorded in the gh#216 loop therefore also ran two
//  in-signature mutants (handler ignores the fresh read / handler drops
//  the delta) and confirmed that test kills both by assertion, not just
//  by API shape.
//

import XCTest
@testable import Done

@MainActor
final class CalendarQuickTagIntentTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var location: EventStorageLocation!

    override func setUp() {
        super.setUp()
        suiteName = "CalendarQuickTagIntentTests-\(UUID().uuidString)"
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

    private func makeFixture() -> (store: EventStore, ctx: CalendarEventOccurrenceContext) {
        let store = makeStore()
        let event = Event(
            title: "Deep Work",
            timeRanges: [.init(start: Date(), end: Date().addingTimeInterval(3600))],
            type: "Study"
        )
        store.addCalendarEvent(event)
        let ctx = CalendarEventOccurrenceContext(
            eventID: event.id,
            occurrenceDate: event.timeRanges[0].start,
            occurrenceID: nil,
            isAllDay: false,
            source: .timelineTap
        )
        return (store, ctx)
    }

    /// Replicates the picker Button's exact computation:
    /// `onToggle(tag.id, !selected)` where
    /// `selected = selection.contains(tag.id)` against the RENDERED set.
    private func tapIntent(tagID: String, renderedSelection: Set<String>) -> Bool {
        !renderedSelection.contains(tagID)
    }

    // MARK: - 1. The fixture the bug demands

    /// Record holds {A}; the last render saw {A}; an external writer adds B
    /// through the store; the user then taps C. Under the old
    /// snapshot-based Button the write was renderedSelection + C = {A, C}
    /// — B silently lost. Intent + tap-time fresh read must land {A, B, C}.
    func testExternalTagWriteBetweenRenderAndTapSurvivesTheTap() throws {
        let (store, ctx) = makeFixture()
        store.upsertLogRecord(for: ctx) { $0.emotions = ["A"] }

        // The render-time snapshot, captured exactly where the picker
        // captures it. Positive control: it must show {A}, or the fixture
        // no longer reproduces the bug's premise.
        let renderedSelection = Set(store.prefilledDraft(for: ctx).emotions)
        XCTAssertEqual(renderedSelection, ["A"], "fixture premise: the render saw exactly {A}")

        // External writer lands between render and tap — through the store,
        // as an agent write / sync round-trip / chat view would.
        store.upsertLogRecord(for: ctx) { $0.emotions = ($0.emotions + ["B"]).sorted() }

        // The tap, as the Button computes it from the (now stale) render.
        store.applyQuickTagIntent(
            axis: .emotions,
            tagID: "C",
            targetSelected: tapIntent(tagID: "C", renderedSelection: renderedSelection),
            for: ctx
        )

        XCTAssertEqual(
            store.logRecord(for: ctx)?.emotions, ["A", "B", "C"],
            "the external write of B must be merged with the user's tap on C, not overwritten by the render-time {A} snapshot"
        )
    }

    // MARK: - 2. Convergence when external and tap touch the SAME tag

    /// External removed A; the user, still seeing A rendered ON, taps to
    /// turn it OFF. The fresh set no longer contains A, so the remove is a
    /// no-op — converging on OFF, which matches BOTH intents.
    func testExternalRemovePlusStaleOffTapConvergesOff() throws {
        let (store, ctx) = makeFixture()
        store.upsertLogRecord(for: ctx) { $0.emotions = ["A"] }
        let renderedSelection = Set(store.prefilledDraft(for: ctx).emotions)
        XCTAssertEqual(renderedSelection, ["A"])

        store.upsertLogRecord(for: ctx) { $0.emotions = [] }

        store.applyQuickTagIntent(
            axis: .emotions,
            tagID: "A",
            targetSelected: tapIntent(tagID: "A", renderedSelection: renderedSelection), // false: rendered ON → turn OFF
            for: ctx
        )

        XCTAssertEqual(
            store.logRecord(for: ctx)?.emotions, [],
            "external remove + stale OFF-tap agree; the write converges on OFF and resurrects nothing"
        )
    }

    /// External added A; the user, still seeing A rendered OFF, taps to
    /// turn it ON. The insert is a no-op — converging on ON with no
    /// duplicate and nothing else disturbed.
    func testExternalAddPlusStaleOnTapConvergesOn() throws {
        let (store, ctx) = makeFixture()
        store.upsertLogRecord(for: ctx) { $0.emotions = [] }
        let renderedSelection = Set(store.prefilledDraft(for: ctx).emotions)
        XCTAssertEqual(renderedSelection, [])

        store.upsertLogRecord(for: ctx) { $0.emotions = ["A"] }

        store.applyQuickTagIntent(
            axis: .emotions,
            tagID: "A",
            targetSelected: tapIntent(tagID: "A", renderedSelection: renderedSelection), // true: rendered OFF → turn ON
            for: ctx
        )

        XCTAssertEqual(
            store.logRecord(for: ctx)?.emotions, ["A"],
            "external add + stale ON-tap agree; the write converges on ON, exactly once"
        )
    }

    // MARK: - 3. Ordering: the handler reads AFTER the external write

    /// The property the whole fix is: the set the write is computed from is
    /// read at HANDLER-CALL time, not captured earlier. The probe is
    /// installed immediately before the handler call (scoped to this
    /// store instance, per the host-app-bundle rule), so every firing is
    /// necessarily a read the handler itself performed — and at each such
    /// read, the store must already hold the external write.
    func testHandlerReadsAfterTheExternalWriteNotBefore() throws {
        let (store, ctx) = makeFixture()
        store.upsertLogRecord(for: ctx) { $0.emotions = ["A"] }
        let renderedSelection = Set(store.prefilledDraft(for: ctx).emotions)

        store.upsertLogRecord(for: ctx) { $0.emotions = ($0.emotions + ["B"]).sorted() }

        var snapshotsAtHandlerReadTime: [[String]] = []
        store.onPrefilledDraftComputed = { [weak store] occurrence in
            snapshotsAtHandlerReadTime.append(store?.logRecord(for: occurrence)?.emotions ?? [])
        }
        store.applyQuickTagIntent(
            axis: .emotions,
            tagID: "C",
            targetSelected: tapIntent(tagID: "C", renderedSelection: renderedSelection),
            for: ctx
        )
        store.onPrefilledDraftComputed = nil

        XCTAssertFalse(
            snapshotsAtHandlerReadTime.isEmpty,
            "the handler must perform its own fresh draft read at call time; zero reads means it wrote from something captured earlier"
        )
        for snapshot in snapshotsAtHandlerReadTime {
            XCTAssertTrue(
                snapshot.contains("B"),
                "every read the handler makes must see the store as it stands AFTER the external write (got \(snapshot))"
            )
        }
        XCTAssertEqual(store.logRecord(for: ctx)?.emotions, ["A", "B", "C"])
    }

    // MARK: - 4. Both pickers: behaviors axis, and axis isolation

    /// The behaviors picker gets the identical merge treatment, and an
    /// intent on one axis never touches the other set.
    func testBehaviorsAxisMergesAndLeavesEmotionsUntouched() throws {
        let (store, ctx) = makeFixture()
        store.upsertLogRecord(for: ctx) {
            $0.behaviors = ["A"]
            $0.emotions = ["E"]
        }
        let renderedSelection = Set(store.prefilledDraft(for: ctx).behaviors)
        XCTAssertEqual(renderedSelection, ["A"])

        store.upsertLogRecord(for: ctx) { $0.behaviors = ($0.behaviors + ["B"]).sorted() }

        store.applyQuickTagIntent(
            axis: .behaviors,
            tagID: "C",
            targetSelected: tapIntent(tagID: "C", renderedSelection: renderedSelection),
            for: ctx
        )

        let record = store.logRecord(for: ctx)
        XCTAssertEqual(record?.behaviors, ["A", "B", "C"], "behaviors axis merges exactly like emotions")
        XCTAssertEqual(record?.emotions, ["E"], "an intent on the behaviors axis must not disturb emotions")
    }

    // MARK: - 5. First tap with no record: seeding still comes from tap time

    /// With no record yet, the tap both seeds the record from the tap-time
    /// prefill (matching the sibling quick-write handlers) and applies the
    /// delta on top of that seed.
    func testFirstTapWithNoRecordSeedsAndAppliesDelta() throws {
        let (store, ctx) = makeFixture()
        XCTAssertNil(store.logRecord(for: ctx), "fixture premise: no record yet")
        let renderedSelection = Set(store.prefilledDraft(for: ctx).emotions)
        XCTAssertEqual(renderedSelection, [])

        store.applyQuickTagIntent(
            axis: .emotions,
            tagID: "A",
            targetSelected: tapIntent(tagID: "A", renderedSelection: renderedSelection),
            for: ctx
        )

        let record = store.logRecord(for: ctx)
        XCTAssertEqual(record?.emotions, ["A"])
        XCTAssertEqual(record?.behaviors, [], "seeding an empty prefill leaves the other axis empty")
        XCTAssertEqual(
            record?.actualDurationMinutes, 60,
            "the seed comes through the tap-time prefilled draft (net scheduled duration), same as the sibling handlers"
        )
    }
}
