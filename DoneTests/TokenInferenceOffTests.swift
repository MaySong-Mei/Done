//
//  TokenInferenceOffTests.swift
//  DoneTests
//
//  gh#282 — token inference is switched off (user decision 2026-10-29). The
//  app no longer creates a `TokenInferenceCoordinator`, so a calendar record,
//  a log change or a feedback change runs no predict / reconcile / bootstrap
//  pass and writes nothing to `TokenInferenceRepository`.
//
//  DoneTests runs inside the real Done.app host, whose `ContentView.onAppear`
//  used to create the coordinator over the host's own store — the source of
//  the token projections that leaked into a simulator's UserDefaults and
//  tripped unrelated fixture guards (`SyncApplierTests`, `SyncCatchUpTests`:
//  "the shared token state is empty"). The host's store is not reachable from
//  a test, so the host half reads the process-wide census of live
//  coordinators instead. The positive control shows the census and the three
//  changes both have teeth: a coordinator built by hand is counted, and the
//  same three changes on the same kind of store DO write projections through
//  it.
//

import UIKit
import XCTest
@testable import Done

@MainActor
final class TokenInferenceOffTests: XCTestCase {

    private var suite = ""
    private var store: EventStore!
    private var isolatedDefaults: UserDefaults!
    /// The shared repository's state before the test, so a regression that
    /// wrote to it can be undone for the tests that run after this one.
    private var sharedBefore: SharedTokenState!

    /// What the shared repository holds, in memory and on disk.
    private struct SharedTokenState: Equatable {
        let dynamic: [TokenDynamicHypothesisRecord]
        let meta: [TokenMetaHypothesisRecord]
        let projections: [TokenOccurrenceProjectionRecord]
        let projectionBytes: Data?

        @MainActor
        static func read() -> SharedTokenState {
            let snapshot = TokenInferenceRepository.shared.snapshot()
            return SharedTokenState(
                dynamic: snapshot.dynamic,
                meta: snapshot.meta,
                projections: snapshot.projections,
                projectionBytes: UserDefaults.standard.data(forKey: TokenInferenceRepository.projectionKey)
            )
        }

        var isEmpty: Bool {
            dynamic.isEmpty && meta.isEmpty && projections.isEmpty && projectionBytes == nil
        }
    }

    override func setUp() {
        super.setUp()
        suite = "TokenInferenceOffTests-\(UUID().uuidString)"
        let location = TestStorage.reset(suite)
        isolatedDefaults = UserDefaults(suiteName: suite + "-tokens")!
        store = EventStore(defaults: UserDefaults(suiteName: suite + "-store")!, storage: location,
                           seedsSampleDataIfEmpty: false)
        sharedBefore = SharedTokenState.read()
    }

    override func tearDown() {
        // A regression that wrote to the shared repository must not leave it
        // for the fixture guards that run later. Only an empty start can be
        // restored exactly.
        if let sharedBefore, sharedBefore.isEmpty, SharedTokenState.read() != sharedBefore {
            TokenInferenceRepository.shared.clearAll()
        }
        TestStorage.tearDown(suite)
        UserDefaults().removePersistentDomain(forName: suite + "-store")
        UserDefaults().removePersistentDomain(forName: suite + "-tokens")
        store = nil
        isolatedDefaults = nil
        super.tearDown()
    }

    private func skipIfTheLLMPathIsOn() throws {
        try XCTSkipIf(UserDefaults.standard.bool(forKey: AppSettingsKeys.tokenInferenceLLMEnabled),
                      "this host has the token LLM on; the deterministic bootstrap is the path under test")
    }

    // MARK: - The three changes

    /// A daily series starting within the hour, so the prediction horizon
    /// holds upcoming occurrences and today's and tomorrow's occurrences
    /// exist for the log and the feedback change.
    private func dailySeries() -> Event {
        let start = Date().addingTimeInterval(3600)
        return Event(title: "Daily", timeRanges: [.init(start: start, end: start.addingTimeInterval(1800))],
                     repeatUnit: .day, repeatInterval: 1)
    }

    private func occurrence(of event: Event, dayOffset: Int) throws -> CalendarEventOccurrenceContext {
        let calendar = Calendar.current
        let day = try XCTUnwrap(calendar.date(byAdding: .day, value: dayOffset,
                                              to: calendar.startOfDay(for: event.timeRanges[0].start)))
        let found = try XCTUnwrap(CalendarLayout.occurrencesForDate([event], date: day, calendar: calendar).first,
                                  "fixture: the series has an occurrence \(dayOffset) day(s) after its first")
        return CalendarEventOccurrenceContext(eventID: event.id, occurrenceDate: day, occurrenceID: found.id,
                                              isAllDay: false, source: .timelineTap)
    }

    private enum Change: CaseIterable, CustomStringConvertible {
        case record, log, feedback
        var description: String {
            switch self {
            case .record: return "calendar record"
            case .log: return "log change"
            case .feedback: return "feedback change"
            }
        }
    }

    /// One change, made through the store's own write path — the path whose
    /// publisher the coordinator subscribed to.
    private func make(_ change: Change, event: Event) throws {
        switch change {
        case .record:
            store.addCalendarEvent(event)
        case .log:
            store.upsertLogRecord(for: try occurrence(of: event, dayOffset: 0)) { $0.effort = 3 }
        case .feedback:
            store.upsertFeedbackRecord(for: try occurrence(of: event, dayOffset: 1)) { $0.effort = 2 }
        }
    }

    private func pump(seconds: Double) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: - The running app host

    private func hostWindowIsUp() -> Bool {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .contains { $0.rootViewController != nil }
    }

    /// The host app's UI is up — its `ContentView.onAppear` has run, which is
    /// where the coordinator used to be created — and no coordinator is
    /// alive anywhere in the process.
    func testTheRunningAppHostWiresNoTokenInferenceCoordinator() async throws {
        let deadline = Date().addingTimeInterval(10)
        while !hostWindowIsUp(), Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(hostWindowIsUp(), "fixture: the host app's window is up, so its root view has appeared")
        XCTAssertEqual(TokenInferenceCoordinator.liveCount, 0, "the app host created a token inference coordinator")
    }

    /// The three changes, each followed by time for any hop a subscriber
    /// would have scheduled, leave the shared repository exactly as it was.
    func testRecordLogAndFeedbackChangesLeaveTheSharedTokenStateUnchanged() async throws {
        try skipIfTheLLMPathIsOn()
        let event = dailySeries()
        for change in Change.allCases {
            try make(change, event: event)
            try await pump(seconds: 0.5)
            XCTAssertEqual(SharedTokenState.read(), sharedBefore, "after the \(change)")
        }
        XCTAssertEqual(store.calendarEventLogRecords.count, 1, "fixture: the log change landed")
        XCTAssertEqual(store.calendarEventFeedbackRecords.count, 1, "fixture: the feedback change landed")
        XCTAssertEqual(TokenInferenceCoordinator.liveCount, 0)
    }

    /// Positive control: the same three changes on the same kind of store,
    /// with a coordinator built by hand over an isolated repository, each
    /// write projections — and the census counts the coordinator while it
    /// lives. Without this, the two tests above could pass because the
    /// changes reach no subscriber at all, or because the census never
    /// counts anything.
    func testPositiveControlTheSameChangesWriteThroughAHandBuiltCoordinator() async throws {
        try skipIfTheLLMPathIsOn()
        let repository = TokenInferenceRepository(defaults: isolatedDefaults)
        var coordinator: TokenInferenceCoordinator? = TokenInferenceCoordinator(
            store: store, service: TokenInferenceService(repository: repository))
        XCTAssertEqual(TokenInferenceCoordinator.liveCount, 1, "the census counts a live coordinator")

        let event = dailySeries()
        var previous = repository.snapshot().projections.map { "\($0.occurrenceKey)/\($0.phase)" }
        XCTAssertTrue(previous.isEmpty, "fixture: an empty isolated repository")
        for change in Change.allCases {
            try make(change, event: event)
            let deadline = Date().addingTimeInterval(5)
            var current = previous
            while current == previous, Date() < deadline {
                try await Task.sleep(for: .milliseconds(20))
                current = repository.snapshot().projections.map { "\($0.occurrenceKey)/\($0.phase)" }
            }
            XCTAssertNotEqual(current, previous, "the \(change) wrote nothing through a live coordinator")
            previous = current
        }
        let phases = Set(repository.snapshot().projections.map(\.phase))
        XCTAssertEqual(phases, [.predicted, .reconciled], "the record predicts; the log and the feedback reconcile")
        XCTAssertEqual(SharedTokenState.read(), sharedBefore, "the control wrote only to its isolated repository")

        coordinator = nil
        XCTAssertNil(coordinator)
        XCTAssertEqual(TokenInferenceCoordinator.liveCount, 0, "the census lets go of a released coordinator")
    }
}
