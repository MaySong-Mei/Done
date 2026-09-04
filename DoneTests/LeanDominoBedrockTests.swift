import XCTest
@testable import Done

/// Empirical shadows of `verification/CivilCalendar/DominoAbsolute.lean`
/// (gh#220 slice 3): the bedrock's NEVER-TOUCH half — which
/// `DominoPushIntervalTests` (thresholds, losslessness) never pinned — plus
/// the frame condition and additivity, each named for its theorem.
@MainActor
final class LeanDominoBedrockTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "LeanDominoBedrockTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        TestStorage.reset(suiteName)
    }

    override func tearDown() {
        TestStorage.tearDown(suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    private func makeStore() -> EventStore {
        EventStore(defaults: defaults,
                   storage: .isolated(name: suiteName),
                   seedsSampleDataIfEmpty: false)
    }

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// Stamp the first push, add the rows, push one hour later; return the
    /// store. `horizonDays` 7 throughout — a start 30 days out is `.future`,
    /// 2 days out is `.nearFuture`.
    private func pushed(_ events: [Event]) -> EventStore {
        let store = makeStore()
        store.dominoPushTodosPastHorizon(now: t0, horizonDays: 7)
        for e in events { store.addCalendarEvent(e) }
        store.dominoPushTodosPastHorizon(now: t0.addingTimeInterval(3600),
                                         horizonDays: 7)
        return store
    }

    private func start(_ store: EventStore, _ id: UUID) -> Date? {
        store.rawCalendarEvents.first { $0.id == id }?.timeRanges.first?.start
    }

    /// THEOREM 24, clause "kind == .todo": an `.event` past the horizon is a
    /// user commitment and never moves.
    func testEventKindIsNeverMoved() {
        let id = UUID()
        let s = t0.addingTimeInterval(30 * 86_400)
        let store = pushed([Event(
            id: id, title: "Commitment",
            timeRanges: [.init(start: s, end: s.addingTimeInterval(3600))],
            kind: .event
        )])
        XCTAssertEqual(start(store, id), s, "an .event moved — bedrock violated")
    }

    /// THEOREM 24, clause "start < horizon": a `.nearFuture` todo is
    /// user-controlled and never moves — the bedrock sentence
    /// (`EventZone.swift:15-23`) with no prior test.
    func testNearFutureTodoIsNeverMoved() {
        let id = UUID()
        let s = t0.addingTimeInterval(2 * 86_400)
        let store = pushed([Event(
            id: id, title: "NearFuture",
            timeRanges: [.init(start: s, end: s.addingTimeInterval(3600))],
            kind: .todo
        )])
        XCTAssertEqual(start(store, id), s, "a .nearFuture todo moved — bedrock violated")
    }

    /// THEOREM 24, clause "absorbed": an absorbed todo lives inside its
    /// parent and never moves independently.
    func testAbsorbedTodoIsNeverMoved() {
        let id = UUID()
        let s = t0.addingTimeInterval(30 * 86_400)
        let store = pushed([Event(
            id: id, title: "Absorbed",
            timeRanges: [.init(start: s, end: s.addingTimeInterval(3600))],
            kind: .todo,
            absorbedIntoEventID: UUID()
        )])
        XCTAssertEqual(start(store, id), s, "an absorbed todo moved")
    }

    /// THEOREM 29 (frame condition): the push slides `timeRanges` and
    /// touches NOTHING else — the deadline (the hard commitment) survives
    /// verbatim while the preferred time moves.
    func testDeadlineSurvivesThePush() {
        let id = UUID()
        let s = t0.addingTimeInterval(30 * 86_400)
        let deadline = t0.addingTimeInterval(60 * 86_400)
        let store = pushed([Event(
            id: id, title: "WithDeadline",
            timeRanges: [.init(start: s, end: s.addingTimeInterval(3600))],
            deadline: deadline,
            kind: .todo
        )])
        let row = store.rawCalendarEvents.first { $0.id == id }
        XCTAssertEqual(row?.timeRanges.first?.start, s.addingTimeInterval(3600),
                       "the eligible todo should have moved by the elapsed hour")
        XCTAssertEqual(row?.deadline, deadline,
                       "the deadline moved — auto-defer touched the commitment")
    }

    /// THEOREM 28 + 27: the push slides both endpoints together (duration
    /// preserved) and keeps the horizon distance exact.
    func testDurationAndHorizonDistancePreserved() {
        let id = UUID()
        let s = t0.addingTimeInterval(30 * 86_400)
        let store = pushed([Event(
            id: id, title: "Slides",
            timeRanges: [.init(start: s, end: s.addingTimeInterval(5400))],
            kind: .todo
        )])
        let range = store.rawCalendarEvents.first { $0.id == id }?.timeRanges.first
        XCTAssertEqual(range.map { $0.end.timeIntervalSince($0.start) }, 5400)
        // horizon advanced by the same 3600 the row moved: distance invariant
        XCTAssertEqual(range?.start, s.addingTimeInterval(3600))
    }

    /// THEOREM 26 (additivity), directly at the store level: two pushes
    /// against advancing horizons equal one push over the whole span — the
    /// same rows, byte-equal starts.
    func testTwoPushesEqualOneWholeSpanPush() {
        let idA = UUID()
        let s = t0.addingTimeInterval(30 * 86_400)
        func makeRow() -> Event {
            Event(id: idA, title: "Additive",
                  timeRanges: [.init(start: s, end: s.addingTimeInterval(3600))],
                  kind: .todo)
        }
        let twoStep = makeStore()
        twoStep.dominoPushTodosPastHorizon(now: t0, horizonDays: 7)
        twoStep.addCalendarEvent(makeRow())
        twoStep.dominoPushTodosPastHorizon(now: t0.addingTimeInterval(3600), horizonDays: 7)
        twoStep.dominoPushTodosPastHorizon(now: t0.addingTimeInterval(9600), horizonDays: 7)

        let oneStep = makeStore()
        oneStep.dominoPushTodosPastHorizon(now: t0, horizonDays: 7)
        oneStep.addCalendarEvent(makeRow())
        oneStep.dominoPushTodosPastHorizon(now: t0.addingTimeInterval(9600), horizonDays: 7)

        XCTAssertEqual(start(twoStep, idA), start(oneStep, idA))
        XCTAssertEqual(start(twoStep, idA), s.addingTimeInterval(9600))
    }
}
