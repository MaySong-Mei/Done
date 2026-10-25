//
//  WristState.swift
//  Shared (Done + DoneWatch)
//
//  The watch's pure state logic, kept platform-free so DoneTests exercises it
//  on the iOS side (the watch target has no test bundle).
//
//  Model: the last `WristSnapshot` from the phone is the truth; commands the
//  watch has sent but the phone has not receipted yet are overlaid on top of
//  it optimistically; and the sessions the user finished from the wrist are
//  hidden even while the phone still projects them as running — the phone
//  clamps every event to a 15-minute minimum, so a Finish within the first
//  quarter hour leaves the event "in progress" on the canvas, and the wrist
//  must not look like the tap was ignored.
//
//  A pending command leaves the overlay when a snapshot carries its receipt,
//  when a snapshot generated after the phone's direct reply arrives (the
//  phone applies before it replies, so that snapshot reflects the command
//  even if the one carrying the receipt was superseded), or after a day.
//
//  Sending is derived from the same list: an entry with no `sentAt` is due.
//  `channel(for:among:reachable:)` is the one rule that keeps a finish from
//  overtaking its start — a later command for an event waits until every
//  earlier one is answered, or follows it on the same FIFO channel.
//

import Foundation

nonisolated enum WristTiming {
    static let gridMinutes = 15
    /// `WristCommandApplier.minimumDuration` — mirrored here so the overlay
    /// predicts the end the phone will actually store.
    static let minimumDuration: TimeInterval = 15 * 60
    /// Focus mode's quick-start block length.
    static let defaultDuration: TimeInterval = 30 * 60
    static let extendStep: TimeInterval = 15 * 60
    /// Dates cross the wire as seconds since 1970 and come back a few
    /// nanoseconds off; two instants this close are the same range start.
    static let instantTolerance: TimeInterval = 0.5

    /// Same rounding as the phone's `calendarSnapDateToMinuteGrid`.
    static func snappedToGrid(_ date: Date) -> Date {
        let granularity = TimeInterval(gridMinutes * 60)
        let snapped = (date.timeIntervalSinceReferenceDate / granularity).rounded() * granularity
        return Date(timeIntervalSinceReferenceDate: snapped)
    }

    /// A start is recorded at the minute the tap happened, never in the
    /// future: a grid-rounded start could land up to 7.5 minutes ahead and
    /// the session would not read as "happening now" until then.
    static func startInstant(_ now: Date) -> Date {
        Date(timeIntervalSinceReferenceDate: (now.timeIntervalSinceReferenceDate / 60).rounded(.down) * 60)
    }

    /// The first end of a wrist start: about half an hour on, ON the grid —
    /// so a later +15 lands exactly fifteen minutes later instead of
    /// wherever the grid snap of an off-grid end falls — and never under the
    /// minimum.
    static func defaultEnd(start: Date) -> Date {
        max(snappedToGrid(start.addingTimeInterval(defaultDuration)), start.addingTimeInterval(minimumDuration))
    }

    /// The end the phone stores for a finish / extend request.
    static func clampedEnd(start: Date, requested: Date) -> Date {
        max(snappedToGrid(requested), start.addingTimeInterval(minimumDuration))
    }

    static func sameInstant(_ a: Date, _ b: Date) -> Bool {
        abs(a.timeIntervalSince(b)) < instantTolerance
    }
}

nonisolated struct WristPendingCommand: Codable, Equatable, Sendable {
    var command: WristCommand
    /// When it was handed to the session; nil means still due.
    var sentAt: Date?
    /// Went out as a user-info transfer (phone out of reach, or the message
    /// failed). Later commands for the same event follow it on that channel.
    var sentAsTransfer: Bool
    /// The phone answered this command directly (a message reply) and
    /// applied it.
    var acknowledgedAt: Date?
    /// Phone clock from that reply: a snapshot generated at or after this
    /// reflects the command, so the overlay can go.
    var settleAfter: Date?

    init(
        command: WristCommand, sentAt: Date? = nil, sentAsTransfer: Bool = false,
        acknowledgedAt: Date? = nil, settleAfter: Date? = nil
    ) {
        self.command = command
        self.sentAt = sentAt
        self.sentAsTransfer = sentAsTransfer
        self.acknowledgedAt = acknowledgedAt
        self.settleAfter = settleAfter
    }

    private enum CodingKeys: String, CodingKey { case command, sentAt, sentAsTransfer, acknowledgedAt, settleAfter }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        command = try c.decode(WristCommand.self, forKey: .command)
        sentAt = try c.decodeIfPresent(Date.self, forKey: .sentAt)
        sentAsTransfer = try c.decodeIfPresent(Bool.self, forKey: .sentAsTransfer) ?? false
        acknowledgedAt = try c.decodeIfPresent(Date.self, forKey: .acknowledgedAt)
        settleAfter = try c.decodeIfPresent(Date.self, forKey: .settleAfter)
    }
}

nonisolated enum WristChannel: Equatable, Sendable {
    case message
    case transfer
}

nonisolated enum WristDisplayState: Equatable, Sendable {
    /// No snapshot has ever arrived: the phone app has not run since the
    /// watch app was installed.
    case noPhoneData
    case idle(types: [WristType], sinceLastRecord: TimeInterval?)
    /// `pending`: a command for this session has not been answered yet.
    case active(WristOccurrence, pending: Bool)
}

nonisolated enum WristStateReducer {
    /// A command the phone never receipted is dropped after this long. A
    /// transfer waits for as long as the phone is away — hours, not
    /// seconds — so the overlay keeps the user's intent on screen for a day;
    /// the occurrence it predicts ends on its own anyway.
    static let pendingTimeout: TimeInterval = 24 * 3600

    // MARK: Sending

    /// Which channel a due entry may use now, or nil to hold it. Earlier
    /// commands for the same event gate it: all answered → whichever channel
    /// is available; all unanswered ones on the transfer channel → the
    /// transfer channel too (FIFO keeps the order); anything else → wait.
    static func channel(
        for entry: WristPendingCommand, among pending: [WristPendingCommand], reachable: Bool
    ) -> WristChannel? {
        let earlier = pending.filter {
            $0.command.eventID == entry.command.eventID && $0.command.id != entry.command.id
                && $0.command.issuedAt < entry.command.issuedAt && $0.acknowledgedAt == nil
        }
        if earlier.isEmpty {
            return reachable ? .message : .transfer
        }
        return earlier.allSatisfy { $0.sentAt != nil && $0.sentAsTransfer } ? .transfer : nil
    }

    /// Apply the phone's direct reply: an applied (or already-applied,
    /// "duplicate") command stays overlaid until a snapshot reflects it; a
    /// rejected one changed nothing and can go at once.
    static func acknowledge(
        _ pending: [WristPendingCommand], receipt: WristReceipt, repliedAt: Date?, now: Date
    ) -> [WristPendingCommand] {
        var result = pending
        guard let i = result.firstIndex(where: { $0.command.id == receipt.id }) else { return result }
        if receipt.outcome == .rejected {
            result.remove(at: i)
        } else {
            result[i].acknowledgedAt = now
            result[i].settleAfter = repliedAt
        }
        return result
    }

    /// A message reply can only reach the process that sent the message.
    /// On activation in a new process, every message still unanswered goes
    /// back to due so it is sent again; the phone answers `duplicate`.
    static func resetMessagesFromAnEarlierProcess(_ pending: [WristPendingCommand]) -> [WristPendingCommand] {
        pending.map { entry in
            var entry = entry
            if entry.sentAt != nil, !entry.sentAsTransfer, entry.acknowledgedAt == nil {
                entry.sentAt = nil
            }
            return entry
        }
    }

    /// Drop pendings the snapshot has receipted or reflects, and those past
    /// the timeout.
    static func settle(
        _ pending: [WristPendingCommand], snapshot: WristSnapshot?, now: Date
    ) -> [WristPendingCommand] {
        let receipted = Set(snapshot?.receipts.map(\.id) ?? [])
        return pending.filter { entry in
            if receipted.contains(entry.command.id) { return false }
            if let settleAfter = entry.settleAfter, let generatedAt = snapshot?.generatedAt,
               generatedAt >= settleAfter {
                return false
            }
            return now.timeIntervalSince(entry.command.issuedAt) < pendingTimeout
        }
    }

    // MARK: Timeline

    /// Focus mode's precedence: an embedded interrupt covering `now` wins,
    /// else the first in-progress occurrence. No overrun grace — a session
    /// that ended is over on the wrist.
    static func current(in occurrences: [WristOccurrence], now: Date) -> WristOccurrence? {
        let inProgress = occurrences.filter { $0.start <= now && $0.end > now }
        if let interrupt = inProgress.first(where: { $0.isInterrupt }) {
            return interrupt
        }
        return inProgress.first
    }

    /// The latest record end. A session finished from the wrist ended at the
    /// tap, whatever clamped end the phone stores for it — so the "since"
    /// counter never jumps when the phone's end comes and goes.
    static func lastRecordEnd(
        in occurrences: [WristOccurrence], finishedAt: [UUID: Date] = [:], now: Date
    ) -> Date? {
        occurrences.compactMap { occurrence -> Date? in
            let end = finishedAt[occurrence.eventID].map { min($0, occurrence.end) } ?? occurrence.end
            return end <= now ? end : nil
        }.max()
    }

    /// Keep a dismissal (event id → tap instant) for as long as its event is
    /// on the overlaid timeline; the window drops it a couple of days on.
    static func pruneDismissed(
        _ dismissed: [UUID: Date], occurrences: [WristOccurrence], now: Date
    ) -> [UUID: Date] {
        let present = Set(occurrences.map(\.eventID))
        return dismissed.filter { present.contains($0.key) }
    }

    /// The snapshot's timeline with the in-flight commands applied in order.
    /// `pendingEventIDs` are the events with a command still unanswered.
    static func overlaid(
        _ snapshot: WristSnapshot, pending: [WristPendingCommand], now: Date
    ) -> (occurrences: [WristOccurrence], pendingEventIDs: Set<UUID>) {
        var occurrences = snapshot.occurrences
        var pendingIDs = Set<UUID>()

        // The range the command names, else the one covering `now`, else the
        // last one of that event.
        func index(of eventID: UUID, rangeStart: Date?) -> Int? {
            if let rangeStart, let named = occurrences.firstIndex(where: {
                $0.eventID == eventID && WristTiming.sameInstant($0.start, rangeStart)
            }) {
                return named
            }
            if let covering = occurrences.firstIndex(where: {
                $0.eventID == eventID && $0.start <= now && $0.end > now
            }) {
                return covering
            }
            return occurrences.lastIndex(where: { $0.eventID == eventID })
        }

        for entry in pending {
            if entry.acknowledgedAt == nil {
                pendingIDs.insert(entry.command.eventID)
            }
            switch entry.command.kind {
            case .start(let eventID, let typeTitle, let start, let end):
                guard !occurrences.contains(where: { $0.eventID == eventID }) else { continue }
                let color = snapshot.types.first { $0.title == typeTitle }?.colorHex ?? "#8E8E93"
                occurrences.append(
                    WristOccurrence(
                        id: "pending-\(eventID.uuidString)", eventID: eventID, title: typeTitle,
                        type: typeTitle, colorHex: color, start: start, end: end,
                        isInterrupt: false, quickActionsEnabled: true
                    )
                )
            case .finish(let eventID, let rangeStart, let at):
                guard let i = index(of: eventID, rangeStart: rangeStart) else { continue }
                occurrences[i].end = WristTiming.clampedEnd(start: occurrences[i].start, requested: at)
            case .extend(let eventID, let rangeStart, let by):
                guard let i = index(of: eventID, rangeStart: rangeStart) else { continue }
                occurrences[i].end = WristTiming.clampedEnd(
                    start: occurrences[i].start, requested: occurrences[i].end.addingTimeInterval(by)
                )
            }
        }
        return (occurrences.sorted { $0.start < $1.start }, pendingIDs)
    }

    /// `dismissed`: event id → the instant Finish was tapped on this watch.
    /// Such an event is hidden while the phone still projects it running,
    /// and counts as a record that ended at the tap.
    static func display(
        snapshot: WristSnapshot?, pending: [WristPendingCommand], dismissed: [UUID: Date], now: Date
    ) -> WristDisplayState {
        guard let snapshot else { return .noPhoneData }
        let (occurrences, pendingIDs) = overlaid(snapshot, pending: pending, now: now)
        let visible = occurrences.filter { dismissed[$0.eventID] == nil }
        if let current = current(in: visible, now: now) {
            return .active(current, pending: pendingIDs.contains(current.eventID))
        }
        let lastEnd = lastRecordEnd(in: occurrences, finishedAt: dismissed, now: now)
        return .idle(types: snapshot.types, sinceLastRecord: lastEnd.map { now.timeIntervalSince($0) })
    }
}
