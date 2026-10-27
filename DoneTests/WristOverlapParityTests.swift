import XCTest
@testable import Done

/// The watch lays overlapping blocks out with its own copy of the phone's
/// day-timeline layout (`WristOverlapLayout`). These run the phone's
/// `CalendarLayout.overlapLayout` and the watch's page on the same random
/// days — built as `Event`s and sent through the real snapshot builder —
/// and require every block to land in the same place.
@MainActor
final class WristOverlapParityTests: XCTestCase {
    private let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        return cal
    }()

    /// 2026-03-10 00:00 UTC.
    private var dayStart: Date { calendar.date(from: DateComponents(year: 2026, month: 3, day: 10))! }
    private var dayEnd: Date { dayStart.addingTimeInterval(86_400) }
    private var now: Date { dayStart.addingTimeInterval(15 * 3600) }

    private struct Rng: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// A day of 2…11 events on the quarter-hour grid: some reaching over
    /// either midnight, identical ranges and shared creation stamps common,
    /// embedded interrupts on a parent (one-off or a daily series), a few
    /// exception instances of that series, and an interrupt whose parent is
    /// not on the day.
    private func randomDay(_ rng: inout Rng) -> [Event] {
        let stamps = (0..<4).map { dayStart.addingTimeInterval(-86_400 * 3 + Double($0) * 0.0004) }
        func stamp() -> Date {
            Bool.random(using: &rng) ? stamps.randomElement(using: &rng)! :
                dayStart.addingTimeInterval(-Double(Int.random(in: 0...500_000, using: &rng)))
        }
        func range() -> Event.TimeRange {
            let s = Int.random(in: -6...96, using: &rng) * 900
            let l = Int.random(in: 1...20, using: &rng) * 900
            return Event.TimeRange(start: dayStart.addingTimeInterval(Double(s)), end: dayStart.addingTimeInterval(Double(s + l)))
        }
        var events: [Event] = []
        var shared: Event.TimeRange?
        for _ in 0..<Int.random(in: 2...9, using: &rng) {
            var r = range()
            if let s = shared, Int.random(in: 0..<4, using: &rng) == 0 { r = s }
            shared = r
            events.append(Event(title: "e", timeRanges: [r], createdAt: stamp(), type: "T"))
        }
        if Bool.random(using: &rng) {
            let s = Int.random(in: 0...80, using: &rng) * 900
            let series = Event(
                title: "s",
                timeRanges: [Event.TimeRange(
                    start: dayStart.addingTimeInterval(Double(s) - 4 * 86_400),
                    end: dayStart.addingTimeInterval(Double(s + Int.random(in: 2...12, using: &rng) * 900) - 4 * 86_400)
                )],
                repeatUnit: .day, createdAt: stamp(), type: "S"
            )
            events.append(series)
            if Bool.random(using: &rng) {
                events.append(Event(title: "x", timeRanges: [range()], createdAt: stamp(), type: "X",
                                    recurrenceParentId: series.id))
            }
        }
        // Interrupts: on a parent of the day, or on one that is not here.
        for _ in 0..<Int.random(in: 0...3, using: &rng) {
            let parent = events.filter { $0.displayKind == .regular }.randomElement(using: &rng)
            let parentID = Int.random(in: 0..<5, using: &rng) == 0 ? UUID() : (parent.map { $0.recurrenceParentId ?? $0.id } ?? UUID())
            let base = parent.flatMap { p -> Event.TimeRange? in
                if p.repeatUnit == .day {
                    return CalendarLayout.occurrencesForDate([p], date: dayStart, calendar: calendar, now: now).first?.range
                }
                return p.timeRanges.first
            } ?? range()
            let span = max(900, base.end.timeIntervalSince(base.start))
            let offset = Double(Int.random(in: -1...Int(span / 900), using: &rng) * 900)
            let r = Event.TimeRange(start: base.start.addingTimeInterval(offset),
                                    end: base.start.addingTimeInterval(offset + Double(Int.random(in: 1...4, using: &rng) * 900)))
            events.append(Event(
                title: "i", timeRanges: [r], createdAt: stamp(), type: "I",
                displayKind: .interrupt,
                interruptRelation: EventInterruptRelation(parentEventID: parentID, occurrenceDate: dayStart)
            ))
        }
        return events.shuffled(using: &rng)
    }

    /// The phone's day column: its occurrences, less the embedded
    /// interrupts its interrupt context draws on their parents.
    private func phoneDay(_ events: [Event]) -> (candidates: [CalendarLayout.EventOccurrence], embedded: [String: String]) {
        let occurrences = CalendarLayout.occurrencesForDate(events, date: dayStart, calendar: calendar, now: now)
        var parents: [UUID: CalendarLayout.EventOccurrence] = [:]
        for occ in occurrences where !occ.event.isInterrupt {
            parents[occ.event.recurrenceParentId ?? occ.event.id] = occ
        }
        var embedded: [String: String] = [:]
        for occ in occurrences {
            guard occ.event.isInterrupt, let rel = occ.event.interruptRelation, rel.state == .embedded,
                  let parent = parents[rel.parentEventID],
                  occ.range.end > parent.range.start && occ.range.start < parent.range.end else { continue }
            embedded[occ.id] = parent.id
        }
        return (occurrences.filter { embedded[$0.id] == nil }, embedded)
    }

    private func watchOccurrences(_ events: [Event]) -> [WristOccurrence] {
        WristSnapshotBuilder.occurrences(events: events, now: now, calendar: calendar, colorHex: { _ in "#888888" })
    }

    private func same(_ a: WristOverlapSlot, _ b: CalendarLayout.EventOverlapSlot) -> Bool {
        abs(a.x - Double(b.xOffsetFraction)) < 1e-9 && abs(a.width - Double(b.widthFraction)) < 1e-9
            && abs(a.zIndex - b.zIndex) < 1e-9 && a.depth == b.depth
            && a.coverRanges.map { [$0.start, $0.end] } == b.coverRanges.map { [$0.start, $0.end] }
    }

    func testTheWatchPageLaysOutEveryDayAsThePhoneDoes() {
        var rng = Rng(state: 0x5A7E)
        var days = 0, blocks = 0, mismatches = 0, peeked = 0, expanded = 0, families = 0, embeddedSeen = 0
        var example = ""
        for _ in 0..<1500 {
            let events = randomDay(&rng)
            let phone = phoneDay(events)
            let slots = CalendarLayout.overlapLayout(
                for: phone.candidates, visibleStart: dayStart, visibleEnd: dayEnd, calendar: calendar, mode: .auto
            )
            let page = WristDayLayout.page(
                watchOccurrences(events), dismissed: [], dayStart: dayStart, dayEnd: dayEnd, now: now, currentID: nil
            )
            days += 1
            XCTAssertEqual(Set(page.blocks.map(\.id)), Set(phone.candidates.map(\.id)).union(phone.embedded.keys))
            for block in page.blocks {
                blocks += 1
                if let parent = phone.embedded[block.id] {
                    embeddedSeen += 1
                    let parentSlot = page.blocks.first { $0.id == parent }?.slot
                    if block.parentID != parent || block.slot.x != parentSlot?.x || block.slot.width != parentSlot?.width
                        || block.slot.zIndex != (parentSlot?.zIndex ?? 0) + 1 {
                        mismatches += 1
                    }
                    continue
                }
                guard let phoneSlot = slots[block.id] else { mismatches += 1; continue }
                if block.slot.depth > 0 { peeked += 1 }
                // A width that is not one column of k: it spans several.
                let columns = 1 / block.slot.width
                if block.slot.depth == 0, abs(columns - columns.rounded()) > 1e-6 { expanded += 1 }
                if block.occurrence.interruptParentID != nil && block.parentID == nil { families += 1 }
                if block.parentID != nil || !same(block.slot, phoneSlot) {
                    mismatches += 1
                    if example.isEmpty {
                        example = "\(block.id): watch \(block.slot) phone \(phoneSlot)"
                    }
                }
            }
        }
        print("PARITY page days=\(days) blocks=\(blocks) mismatches=\(mismatches) peekedChildren=\(peeked) expandedTwoThirds=\(expanded) unparentedInterrupts=\(families) embedded=\(embeddedSeen)")
        XCTAssertEqual(mismatches, 0, example)
        // Positive controls: the days reach every rule.
        XCTAssertGreaterThan(peeked, 100, "stack-peek happens")
        XCTAssertGreaterThan(expanded, 20, "rightward expansion happens")
        XCTAssertGreaterThan(embeddedSeen, 100, "interrupts are drawn on parents")
        XCTAssertGreaterThan(families, 20, "interrupts whose parent is elsewhere still pack")
    }

    /// The core on its own, both modes, on the phone's own occurrences —
    /// including the draft the phone feeds in while one is drawn.
    func testTheCoreAgreesInBothModes() {
        var rng = Rng(state: 0xC0DE)
        var compared = 0, mismatches = 0
        var example = ""
        for _ in 0..<1500 {
            var candidates = phoneDay(randomDay(&rng)).candidates
            let s = Int.random(in: 0...92, using: &rng) * 900
            let draft = Event.TimeRange(start: dayStart.addingTimeInterval(Double(s)),
                                        end: dayStart.addingTimeInterval(Double(s + Int.random(in: 1...8, using: &rng) * 900)))
            for mode in [CalendarLayout.OverlapMode.auto, .equalSplit] {
                if mode == .equalSplit {
                    candidates.append(CalendarLayout.EventOccurrence(
                        id: WristDayLayout.draftID, event: Event(title: "", createdAt: .distantFuture), range: draft
                    ))
                }
                let phone = CalendarLayout.overlapLayout(
                    for: candidates, visibleStart: dayStart, visibleEnd: dayEnd, calendar: calendar, mode: mode
                )
                let items = candidates.map { occ in
                    WristOverlapItem(
                        id: occ.id, start: occ.range.start, end: occ.range.end, createdAt: occ.event.createdAt,
                        anchorID: occ.event.recurrenceParentId ?? occ.event.id,
                        embeddedParentID: occ.event.interruptRelation?.state == .embedded
                            ? occ.event.interruptRelation?.parentEventID : nil,
                        isInterrupt: occ.event.isInterrupt
                    )
                }
                let watch = WristOverlapLayout.slots(
                    for: items, visibleStart: dayStart, visibleEnd: dayEnd, mode: mode == .auto ? .auto : .equalSplit
                )
                for occ in candidates {
                    compared += 1
                    guard let w = watch[occ.id], let p = phone[occ.id], same(w, p) else {
                        mismatches += 1
                        if example.isEmpty { example = "\(mode) \(occ.id): \(String(describing: watch[occ.id])) vs \(String(describing: phone[occ.id]))" }
                        continue
                    }
                }
            }
        }
        print("PARITY core compared=\(compared) mismatches=\(mismatches)")
        XCTAssertEqual(mismatches, 0, example)
    }

    /// Focus mode's "current event" and the watch's running bar name the
    /// same event on random days with several things in progress at once.
    func testTheRunningBarShowsWhatFocusModeShows() {
        var rng = Rng(state: 0xF0C5)
        var checked = 0, several = 0, disagreements = 0
        var example = ""
        for _ in 0..<1500 {
            let events = randomDay(&rng)
            let at = dayStart.addingTimeInterval(Double(Int.random(in: 0...95, using: &rng) * 900 + 450))
            let phone = focusCurrentOccurrence(
                in: CalendarLayout.occurrencesForDate(events, date: at, calendar: calendar, now: at), now: at, overrunGrace: 0
            )
            let wrist = WristStateReducer.current(
                in: WristSnapshotBuilder.occurrences(events: events, now: at, calendar: calendar, colorHex: { _ in "#888888" }),
                now: at
            )
            checked += 1
            let inProgress = CalendarLayout.occurrencesForDate(events, date: at, calendar: calendar, now: at)
                .filter { $0.range.start <= at && $0.range.end > at }
            if inProgress.count > 1 { several += 1 }
            if phone?.event.id != wrist?.eventID || phone.map({ $0.range.start }) != wrist?.start {
                disagreements += 1
                if example.isEmpty { example = "phone \(String(describing: phone?.id)) watch \(String(describing: wrist?.id))" }
            }
        }
        print("PARITY current checked=\(checked) severalInProgress=\(several) disagreements=\(disagreements)")
        XCTAssertEqual(disagreements, 0, example)
        XCTAssertGreaterThan(several, 150, "positive control: overlaps in progress happen")
    }
}
