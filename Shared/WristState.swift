//
//  WristState.swift
//  Shared (Done + DoneWatch)
//
//  The watch's pure state logic, kept platform-free so DoneTests exercises it
//  on the iOS side (the watch target has no test bundle).
//
//  Model: the last `WristSnapshot` from the phone is the truth; commands the
//  watch has sent but the phone has not receipted yet are overlaid on top of
//  it optimistically; and the eventIDs the user finished from the wrist are
//  hidden even while the phone still projects them as running — the phone
//  clamps every event to a 15-minute minimum, so a Finish within the first
//  quarter hour leaves the event "in progress" on the canvas, and the wrist
//  must not look like the tap was ignored.
//

import Foundation

enum WristTiming {
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

    /// The end the phone stores for a finish / extend request.
    static func clampedEnd(start: Date, requested: Date) -> Date {
        max(snappedToGrid(requested), start.addingTimeInterval(minimumDuration))
    }
}

struct WristPendingCommand: Codable, Equatable, Sendable {
    var command: WristCommand
}

enum WristDisplayState: Equatable, Sendable {
    /// No snapshot has ever arrived: the phone app has not run since the
    /// watch app was installed.
    case noPhoneData
    case idle(types: [WristType], sinceLastRecord: TimeInterval?)
    case active(WristOccurrence, pending: Bool)
}

enum WristStateReducer {
    /// A command the phone never receipted is dropped after this long and the
    /// snapshot shows unmodified again.
    static let pendingTimeout: TimeInterval = 90

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

    /// Keep only the dismissed ids that still cover `now` on the overlaid
    /// timeline — once the event has ended on its own the hide is moot.
    static func pruneDismissed(
        _ dismissed: Set<UUID>, occurrences: [WristOccurrence], now: Date
    ) -> Set<UUID> {
        let live = Set(occurrences.filter { $0.start <= now && $0.end > now }.map(\.eventID))
        return dismissed.intersection(live)
    }

    /// The snapshot's timeline with the in-flight commands applied in order.
    static func overlaid(
        _ snapshot: WristSnapshot, pending: [WristPendingCommand], now: Date
    ) -> (occurrences: [WristOccurrence], pendingEventIDs: Set<UUID>) {
        var occurrences = snapshot.occurrences
        var pendingIDs = Set<UUID>()

        func index(of eventID: UUID) -> Int? {
            // A multi-range event projects several occurrences; edit the one
            // covering `now`, else the last one (the phone edits range 0, but
            // what the user sees running is the one to predict).
            if let covering = occurrences.firstIndex(where: {
                $0.eventID == eventID && $0.start <= now && $0.end > now
            }) {
                return covering
            }
            return occurrences.lastIndex(where: { $0.eventID == eventID })
        }

        for entry in pending {
            switch entry.command.kind {
            case .start(let eventID, let typeTitle, let start, let end):
                pendingIDs.insert(eventID)
                guard !occurrences.contains(where: { $0.eventID == eventID }) else { continue }
                let color = snapshot.types.first { $0.title == typeTitle }?.colorHex ?? "#8E8E93"
                occurrences.append(
                    WristOccurrence(
                        id: "pending-\(eventID.uuidString)", eventID: eventID, title: typeTitle,
                        type: typeTitle, colorHex: color, start: start, end: end,
                        isInterrupt: false, quickActionsEnabled: true
                    )
                )
            case .finish(let eventID, let at):
                guard let i = index(of: eventID) else { continue }
                pendingIDs.insert(eventID)
                occurrences[i].end = WristTiming.clampedEnd(start: occurrences[i].start, requested: at)
            case .extend(let eventID, let by):
                guard let i = index(of: eventID) else { continue }
                pendingIDs.insert(eventID)
                occurrences[i].end = WristTiming.clampedEnd(
                    start: occurrences[i].start, requested: occurrences[i].end.addingTimeInterval(by)
                )
            }
        }
        return (occurrences.sorted { $0.start < $1.start }, pendingIDs)
    }

    static func display(
        snapshot: WristSnapshot?, pending: [WristPendingCommand], dismissed: Set<UUID>, now: Date
    ) -> WristDisplayState {
        guard let snapshot else { return .noPhoneData }
        let (occurrences, pendingIDs) = overlaid(snapshot, pending: pending, now: now)
        let visible = occurrences.filter { !dismissed.contains($0.eventID) }
        if let current = current(in: visible, now: now) {
            return .active(current, pending: pendingIDs.contains(current.eventID))
        }
        var lastEnd = lastRecordEnd(in: occurrences, now: now)
        // A session finished from the wrist counts as a record that ended at
        // the tap, even while the phone's clamped end is still ahead.
        for occurrence in occurrences where dismissed.contains(occurrence.eventID) && occurrence.start <= now {
            lastEnd = max(lastEnd ?? .distantPast, min(occurrence.end, now))
        }
        return .idle(types: snapshot.types, sinceLastRecord: lastEnd.map { now.timeIntervalSince($0) })
    }
}
