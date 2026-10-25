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
//  A pending command leaves the overlay only when a snapshot carries its
//  receipt (or after a day). The phone's direct reply to a message is an
//  acknowledgement: it ends the "sending" hint, nothing more, because the
//  reply and the snapshot travel on different channels and the snapshot is
//  what holds the resulting occurrence.
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
}

nonisolated struct WristPendingCommand: Codable, Equatable, Sendable {
    var command: WristCommand
    /// Set when the phone answered this command directly (a message reply).
    var acknowledgedAt: Date?
    /// Went out as a user-info transfer (phone out of reach, or the message
    /// failed). Later commands for the same event must not overtake it on
    /// the message channel.
    var sentAsTransfer: Bool

    init(command: WristCommand, acknowledgedAt: Date? = nil, sentAsTransfer: Bool = false) {
        self.command = command
        self.acknowledgedAt = acknowledgedAt
        self.sentAsTransfer = sentAsTransfer
    }

    private enum CodingKeys: String, CodingKey { case command, acknowledgedAt, sentAsTransfer }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        command = try c.decode(WristCommand.self, forKey: .command)
        acknowledgedAt = try c.decodeIfPresent(Date.self, forKey: .acknowledgedAt)
        sentAsTransfer = try c.decodeIfPresent(Bool.self, forKey: .sentAsTransfer) ?? false
    }
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

    static func lastRecordEnd(in occurrences: [WristOccurrence], now: Date) -> Date? {
        occurrences.filter { $0.end <= now }.map(\.end).max()
    }

    /// Drop pendings the snapshot has receipted, and those past the timeout.
    static func settle(
        _ pending: [WristPendingCommand], snapshot: WristSnapshot?, now: Date
    ) -> [WristPendingCommand] {
        let receipted = Set(snapshot?.receipts.map(\.id) ?? [])
        return pending.filter { entry in
            !receipted.contains(entry.command.id)
                && now.timeIntervalSince(entry.command.issuedAt) < pendingTimeout
        }
    }

    /// Keep only the dismissals whose event still covers `now` on the
    /// overlaid timeline — once the event has ended on its own the hide is
    /// moot. Values are the tap instants.
    static func pruneDismissed(
        _ dismissed: [UUID: Date], occurrences: [WristOccurrence], now: Date
    ) -> [UUID: Date] {
        let live = Set(occurrences.filter { $0.start <= now && $0.end > now }.map(\.eventID))
        return dismissed.filter { live.contains($0.key) }
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
            if let rangeStart,
               let named = occurrences.firstIndex(where: { $0.eventID == eventID && $0.start == rangeStart }) {
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

    static func display(
        snapshot: WristSnapshot?, pending: [WristPendingCommand], dismissed: [UUID: Date], now: Date
    ) -> WristDisplayState {
        guard let snapshot else { return .noPhoneData }
        let (occurrences, pendingIDs) = overlaid(snapshot, pending: pending, now: now)
        let visible = occurrences.filter { dismissed[$0.eventID] == nil }
        if let current = current(in: visible, now: now) {
            return .active(current, pending: pendingIDs.contains(current.eventID))
        }
        var lastEnd = lastRecordEnd(in: occurrences, now: now)
        // A session finished from the wrist counts as a record that ended at
        // the tap, even while the phone's clamped end is still ahead.
        for (eventID, tappedAt) in dismissed
        where occurrences.contains(where: { $0.eventID == eventID && $0.start <= now }) {
            lastEnd = max(lastEnd ?? .distantPast, min(tappedAt, now))
        }
        return .idle(types: snapshot.types, sinceLastRecord: lastEnd.map { now.timeIntervalSince($0) })
    }
}
