//
//  WristEndCrown.swift
//  Shared (Done + DoneWatch)
//
//  The watch's event page as data: which event it shows (the subject), and
//  what the Digital Crown does to that event's end — as data, so DoneTests
//  can pin it. The watch's view only turns detents into calls.
//

import Foundation

/// The event the event page shows: the block selected on Today, else the
/// running session, else none (the page's empty state).
nonisolated struct WristEventSubject: Equatable, Sendable {
    enum Source: Equatable, Sendable {
        case selected
        case running
    }

    var source: Source
    var occurrence: WristOccurrence
    /// The subject's identity from one snapshot to the next: the block's
    /// motion key (`WristDayBlock.motionKey`), or, for a running session
    /// with no block on the page, its event id.
    var key: String
    /// The running session, however it became the subject: its end has a
    /// floor ahead of now, and the page offers +15 and Finish.
    var isRunning: Bool

    /// Which range of which event: the identity a selection and a turn
    /// hold. Stable while the phone adds or removes the event's other
    /// ranges (a motion key, "event#ordinal", is not: it then names
    /// another range); a range whose start moves is another range.
    struct Selection: Hashable, Sendable {
        var eventID: UUID
        var rangeStart: Date

        init(eventID: UUID, rangeStart: Date) {
            self.eventID = eventID
            self.rangeStart = rangeStart
        }

        init(_ occurrence: WristOccurrence) {
            self.init(eventID: occurrence.eventID, rangeStart: occurrence.start)
        }

        func matches(_ occurrence: WristOccurrence) -> Bool {
            occurrence.eventID == eventID && WristTiming.sameInstant(occurrence.start, rangeStart)
        }
    }

    /// The subject's range identity.
    var selection: Selection { Selection(occurrence) }

    /// `selection` is Today's selection; `running` the running session
    /// (`WristDisplayState.active`). A selection no longer among `blocks`
    /// counts as none.
    static func resolve(selection: Selection?, blocks: [WristDayBlock], running: WristOccurrence?) -> WristEventSubject? {
        let block = selection.flatMap { selection in blocks.first { selection.matches($0.occurrence) } }
        return resolve(block: block, blocks: blocks, running: running)
    }

    /// The same, with the selection named by a block's motion key.
    static func resolve(selectedKey: String?, blocks: [WristDayBlock], running: WristOccurrence?) -> WristEventSubject? {
        let block = selectedKey.flatMap { key in blocks.first { $0.motionKey == key } }
        return resolve(block: block, blocks: blocks, running: running)
    }

    private static func resolve(block: WristDayBlock?, blocks: [WristDayBlock], running: WristOccurrence?) -> WristEventSubject? {
        if let block {
            let isRunning = running.map { $0.id == block.occurrence.id } ?? false
            return WristEventSubject(source: .selected, occurrence: block.occurrence, key: block.motionKey, isRunning: isRunning)
        }
        if let running {
            let key = blocks.first(where: { $0.occurrence.id == running.id })?.motionKey ?? running.eventID.uuidString
            return WristEventSubject(source: .running, occurrence: running, key: key, isRunning: true)
        }
        return nil
    }

    /// The other blocks' edges the end can stop on (the drag's magnet): their
    /// own ranges, not the day's clipped ones, and only the start of a
    /// running timer (its end is a placeholder). Only blocks the phone has:
    /// not the events this watch created that it has not reflected yet
    /// (`localCreates`) — an edge the phone does not know it would round
    /// away.
    static func neighbourEdges(of key: String, in blocks: [WristDayBlock], localCreates: Set<UUID> = []) -> [Date] {
        blocks.filter { $0.motionKey != key && !localCreates.contains($0.occurrence.eventID) }.flatMap { other -> [Date] in
            other.occurrence.isOpenEnded ? [other.occurrence.start] : [other.occurrence.start, other.occurrence.end]
        }
    }
}

/// The crown on the event page: each detent moves the subject's end one
/// stop, and the change is sent once the crown rests (`restDelay`), or at
/// once when the page is left first.
///
/// The stops are exactly the ends the phone keeps as they are
/// (`WristRangeEdit.settled`, the rule both sides share), taken from the
/// 15-minute grid, other blocks' edges and the shortest the event may be —
/// so an end off the grid goes to the next grid mark in the direction
/// turned, then a quarter hour a detent. The event's own end is always a
/// stop too, though nothing is sent for it. Past the first or last stop the
/// crown goes nowhere and says so (`Step.limit`).
///
/// The crown counts toward a time, not by a difference. When the day under
/// a turn changes (a send lands, the phone puts one back or moves the
/// event, a minute passes), a change not yet sent — or sent and not yet on
/// the day — keeps its time while the phone would still keep it, else goes
/// to the nearest stop the new day allows on the same side of the end (a
/// turn that shortened the event never becomes one that lengthens it), or
/// back to the end; otherwise the turn starts over from where the event
/// now ends.
nonisolated struct WristEndCrown: Equatable, Sendable {
    /// The rotation `digitalCrownRotation` reports, as a sign, for the turn
    /// that scrolls Today toward later hours: that turn makes the end
    /// later. Not yet measured on a watch.
    static let crownLater = 1

    /// The direction of the end (+1 later, -1 earlier) for a crown delta.
    static func direction(ofCrownDelta delta: Int) -> Int {
        delta.signum() * crownLater
    }

    /// Why the crown cannot move the subject's end: the page says so
    /// instead.
    enum Refusal: Equatable, Sendable {
        /// A phone from before range edits.
        case phoneTooOld
        /// A repeating event, or a phone timer whose end the phone sets
        /// when it stops (`WristOccurrence.quickActionsEnabled`,
        /// `isOpenEnded`).
        case notEditable
        /// Its end is on another day than today's.
        case endsAnotherDay
    }

    /// The event as the crown sees it.
    struct Config: Equatable, Sendable {
        var start: Date
        var end: Date
        /// The earliest and latest the end may go.
        var floor: Date
        var ceiling: Date
        /// Other blocks' edges the end can stop on.
        var edges: [Date]
        /// The running session: what is sent must still end after the real
        /// time it is sent at (`takeUnsent(now:)`).
        var running = false
    }

    enum Availability: Equatable, Sendable {
        case moves(Config)
        case refused(Refusal)
    }

    /// What the crown may do for an event of today's page.
    ///
    /// A running session is not ended by the crown — that is Finish — so its
    /// end goes no earlier than the first grid mark at least `runningLead`
    /// after `now` (21:26 → 21:30, 21:29 → 21:45): shortened that far, not
    /// ended. `now` is the page's minute, behind the real time by up to a
    /// minute, so the send checks again against the real time
    /// (`takeUnsent(now:)`). An event in from yesterday keeps at least a
    /// quarter hour on the page.
    static func availability(
        start: Date, end: Date, isOpenEnded: Bool, quickActionsEnabled: Bool, isRunning: Bool,
        takesRangeEdits: Bool, dayStart: Date, dayEnd: Date, now: Date, edges: [Date]
    ) -> Availability {
        guard takesRangeEdits else { return .refused(.phoneTooOld) }
        guard quickActionsEnabled, !isOpenEnded else { return .refused(.notEditable) }
        guard end <= dayEnd, end > dayStart else { return .refused(.endsAnotherDay) }
        var floor = max(start.addingTimeInterval(WristTiming.minimumDuration), dayStart.addingTimeInterval(quarter))
        if isRunning { floor = max(floor, runningFloor(now)) }
        let inDay = edges.filter { $0 > dayStart && $0 <= dayEnd }
        return .moves(Config(start: start, end: end, floor: floor, ceiling: dayEnd, edges: inDay, running: isRunning))
    }

    /// `availability` for a subject on the page.
    static func availability(
        for subject: WristEventSubject, blocks: [WristDayBlock], takesRangeEdits: Bool,
        dayStart: Date, dayEnd: Date, now: Date, localCreates: Set<UUID> = []
    ) -> Availability {
        let occurrence = subject.occurrence
        return availability(
            start: occurrence.start, end: occurrence.end, isOpenEnded: occurrence.isOpenEnded,
            quickActionsEnabled: occurrence.quickActionsEnabled, isRunning: subject.isRunning,
            takesRangeEdits: takesRangeEdits, dayStart: dayStart, dayEnd: dayEnd, now: now,
            edges: WristEventSubject.neighbourEdges(of: subject.key, in: blocks, localCreates: localCreates)
        )
    }

    /// The crown's step.
    static let quarter = TimeInterval(WristTiming.gridMinutes * 60)
    /// How long the crown rests before the change is sent.
    static let restDelay: TimeInterval = 0.7
    /// How far ahead of now a running session's end must stay.
    static let runningLead: TimeInterval = 2 * 60

    /// The first grid mark at or after `date`.
    static func markAtOrAfter(_ date: Date) -> Date {
        Date(timeIntervalSinceReferenceDate: (date.timeIntervalSinceReferenceDate / quarter).rounded(.up) * quarter)
    }

    /// The earliest a running session's end may go at `now`: the first grid
    /// mark at least `runningLead` after it.
    static func runningFloor(_ now: Date) -> Date {
        markAtOrAfter(now.addingTimeInterval(runningLead))
    }

    private(set) var config: Config
    private(set) var stops: [Date]
    private(set) var index: Int
    /// The last end sent, until the day shows the event ending there (or
    /// `release`).
    private(set) var sent: Date?
    /// The end the turn was made from: which way it went is the target's
    /// side of this, whatever the day does to the end meanwhile.
    private(set) var anchor: Date

    init(_ config: Config) {
        self.config = config
        stops = Self.stops(for: config, keeping: nil)
        index = Self.nearest(config.end, in: stops)
        sent = nil
        anchor = config.end
    }

    /// Where the end is going: the end the page shows.
    var target: Date { stops[index] }

    /// A change the crown made that has not been sent.
    var hasUnsent: Bool {
        !WristTiming.sameInstant(target, config.end) && !(sent.map { WristTiming.sameInstant($0, target) } ?? false)
    }

    /// A change sent that the day does not show yet.
    var inFlight: Bool {
        sent.map { !WristTiming.sameInstant($0, config.end) } ?? false
    }

    enum Step: Equatable, Sendable {
        case moved
        /// Nothing further that way: the shortest the event may be, the end
        /// of the day, or (running) the floor ahead of now.
        case limit
    }

    /// One stop of the end: +1 later, -1 earlier (`direction(ofCrownDelta:)`).
    mutating func turn(_ direction: Int) -> Step {
        guard direction != 0 else { return .limit }
        let next = index + (direction > 0 ? 1 : -1)
        guard stops.indices.contains(next) else { return .limit }
        index = next
        return .moved
    }

    /// The change not yet sent, as the range to send, marked sent. Nil when
    /// there is none. With `now` (the real time it goes at), a running
    /// session's end no longer `runningLead` ahead of it is lifted to the
    /// first stop that is, on the side of the end the turn went; none, and
    /// nothing is sent — the crown never ends the session.
    mutating func takeUnsent(now: Date? = nil) -> WristTimeSpan? {
        if let now, config.running, target < now.addingTimeInterval(Self.runningLead), hasUnsent {
            let floor = Self.runningFloor(now)
            let turned = target
            if let ahead = stops.firstIndex(where: {
                $0 >= floor && !WristTiming.sameInstant($0, config.end) && Self.onSameSide($0, as: turned, of: anchor)
            }) {
                index = ahead
            } else {
                index = Self.nearest(config.end, in: stops)
                return nil
            }
        }
        guard hasUnsent else { return nil }
        sent = target
        return WristTimeSpan(start: config.start, end: target)
    }

    /// The day under the turn changed. A change not sent, or sent and not
    /// yet on the day, keeps its time while the phone would keep it (else
    /// the nearest stop on the same side of the end, or the end itself);
    /// otherwise — the send landed, or nothing was turned — the turn starts
    /// over at the event's end.
    mutating func update(_ new: Config) {
        guard new != config else { return }
        let waiting = sent.map { !WristTiming.sameInstant($0, new.end) } ?? false
        if hasUnsent || waiting {
            let keep = target
            // The way the turn went, from the end it was made from: kept
            // only while it still goes that way from the new end — a later
            // turn the phone's end has reached or passed is done (or
            // undone), never sent as a shortening, nor the other way.
            let later = keep > anchor
            guard !WristTiming.sameInstant(keep, new.end), (keep > new.end) == later else {
                config = new
                rebase()
                return
            }
            config = new
            anchor = new.end
            stops = Self.stops(for: new, keeping: keep)
            index = Self.index(keeping: keep, in: stops, config: new, anchor: anchor)
        } else {
            config = new
            rebase()
        }
    }

    /// The phone has answered the send (or never will): stop waiting for
    /// the day to show it, and count from the event's end again — unless a
    /// newer change is waiting to go.
    mutating func release() {
        guard sent != nil, !hasUnsent else { return }
        rebase()
    }

    private mutating func rebase() {
        sent = nil
        anchor = config.end
        stops = Self.stops(for: config, keeping: nil)
        index = Self.nearest(config.end, in: stops)
    }

    /// Whether the phone keeps `end` for the event as it is: what the watch
    /// shows is what the phone stores.
    static func keeps(_ end: Date, for config: Config) -> Bool {
        WristRangeEdit.settled(
            original: WristTimeSpan(start: config.start, end: config.end),
            requested: WristTimeSpan(start: config.start, end: end), edges: config.edges
        ) == WristTimeSpan(start: config.start, end: end)
    }

    /// Every end the crown can stop on, in order. The event's end is always
    /// one (even outside the limits, so the first detent moves toward
    /// them); so is a kept time within them that the phone keeps.
    static func stops(for config: Config, keeping kept: Date?) -> [Date] {
        var candidates: [Date] = []
        if config.ceiling >= config.floor {
            candidates.append(config.floor)
            candidates.append(config.ceiling)
            var mark = markAtOrAfter(config.floor)
            while mark <= config.ceiling {
                candidates.append(mark)
                mark = mark.addingTimeInterval(quarter)
            }
            candidates += config.edges.filter { $0 >= config.floor && $0 <= config.ceiling }
            if let kept, kept >= config.floor, kept <= config.ceiling { candidates.append(kept) }
        }
        candidates = candidates.filter { WristTiming.sameInstant($0, config.end) || keeps($0, for: config) }
        var all = [config.end] + candidates
        all.sort()
        var unique: [Date] = []
        for date in all where !(unique.last.map { WristTiming.sameInstant($0, date) } ?? false) {
            unique.append(date)
        }
        // A stop within a wire tolerance of the event's end is that end.
        return unique.map { WristTiming.sameInstant($0, config.end) ? config.end : $0 }
    }

    /// Where a kept time lands among the new stops: on itself if it is one;
    /// else the nearest stop the same way from the end the turn was made
    /// from (`anchor`) — a turn that shortened the event never becomes one
    /// that lengthens it, nor the other way round — other than the event's
    /// own end; none, and back to the end, with nothing to send.
    private static func index(keeping keep: Date, in stops: [Date], config: Config, anchor: Date) -> Int {
        if let same = stops.firstIndex(where: { WristTiming.sameInstant($0, keep) }) { return same }
        let sameSide = stops.indices.filter {
            !WristTiming.sameInstant(stops[$0], config.end) && onSameSide(stops[$0], as: keep, of: anchor)
        }
        guard let best = sameSide.min(by: {
            abs(stops[$0].timeIntervalSince(keep)) < abs(stops[$1].timeIntervalSince(keep))
        }) else { return nearest(config.end, in: stops) }
        return best
    }

    /// Whether `stop` and `kept` are both later than `end`, or both earlier.
    private static func onSameSide(_ stop: Date, as kept: Date, of end: Date) -> Bool {
        guard !WristTiming.sameInstant(stop, end), !WristTiming.sameInstant(kept, end) else { return false }
        return (stop > end) == (kept > end)
    }

    private static func nearest(_ date: Date, in stops: [Date]) -> Int {
        var best = 0
        for i in stops.indices where abs(stops[i].timeIntervalSince(date)) < abs(stops[best].timeIntervalSince(date)) {
            best = i
        }
        return best
    }
}

/// The crown's turn as the event page holds it across subjects: one turn,
/// for one subject. A turn belongs to the subject it was made on — when the
/// subject becomes another event (the selection changed, the event left the
/// day, the running session ended and another took over) a turn not yet
/// sent is dropped, never applied to the new subject; when the same subject
/// stops being one the crown moves (now repeating, a phone timer) it is
/// dropped too, since the phone would refuse it.
nonisolated struct WristEndCrownSession: Equatable, Sendable {
    /// What goes to the phone: `WristSessionClient.editRange(occurrence,
    /// start:end:)`.
    struct Send: Equatable, Sendable {
        var occurrence: WristOccurrence
        var start: Date
        var end: Date
    }

    private(set) var key: String?
    /// The subject's range: a turn belongs to it, and to no other.
    private(set) var range: WristEventSubject.Selection?
    private(set) var occurrence: WristOccurrence?
    /// Nil when the crown cannot move the subject's end (or there is none).
    private(set) var crown: WristEndCrown?

    init() {}

    /// The page's subject as of now, and what the crown may do with it.
    /// True when a turn not yet sent was dropped.
    @discardableResult
    mutating func show(_ subject: WristEventSubject?, availability: WristEndCrown.Availability?) -> Bool {
        let config: WristEndCrown.Config? = {
            if case .moves(let config) = availability { return config }
            return nil
        }()
        guard let subject else {
            let dropped = crown?.hasUnsent ?? false
            key = nil
            range = nil
            occurrence = nil
            crown = nil
            return dropped
        }
        key = subject.key
        if subject.selection != range {
            let dropped = crown?.hasUnsent ?? false
            range = subject.selection
            occurrence = subject.occurrence
            crown = config.map(WristEndCrown.init)
            return dropped
        }
        occurrence = subject.occurrence
        guard let config else {
            let dropped = crown?.hasUnsent ?? false
            crown = nil
            return dropped
        }
        if crown == nil { crown = WristEndCrown(config) } else { crown?.update(config) }
        return false
    }

    /// The end the page shows: where the crown is going, else the event's.
    var shownEnd: Date? { crown?.target ?? occurrence?.end }

    /// One crown delta as reported by `digitalCrownRotation` (detents, in
    /// its sign): each detent a stop. Nil when there is nothing to move.
    mutating func turn(crownDelta: Int) -> (moved: Bool, limited: Bool)? {
        guard crown != nil, crownDelta != 0 else { return nil }
        let direction = WristEndCrown.direction(ofCrownDelta: crownDelta)
        var moved = false
        var limited = false
        for _ in 0..<abs(crownDelta) {
            switch crown?.turn(direction) {
            case .moved: moved = true
            case .limit: limited = true
            case nil: break
            }
        }
        return (moved, limited)
    }

    /// The change not yet sent, as of the real time `now`, marked sent.
    mutating func takeUnsent(now: Date) -> Send? {
        guard let occurrence, let span = crown?.takeUnsent(now: now) else { return nil }
        return Send(occurrence: occurrence, start: span.start, end: span.end)
    }

    /// The subject is no longer waiting on the phone (`pendingEventIDs`
    /// without it): a send the day never showed is let go.
    mutating func settle(pendingEventIDs: Set<UUID>) {
        guard let occurrence, !pendingEventIDs.contains(occurrence.eventID) else { return }
        crown?.release()
    }

    /// Finish was tapped: a turn not yet sent is let go — Finish says when
    /// the event ends.
    mutating func discardUnsent() {
        crown = crown.map { WristEndCrown($0.config) }
    }
}
