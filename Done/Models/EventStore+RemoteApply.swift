//
//  EventStore+RemoteApply.swift
//  Done
//
//  The store side of the remote applier (design §6 / §6.1 of
//  Docs/sync/00-realtime-sync-design.md): the one entry point, and the
//  in-memory writes its second pass makes. The decisions live in
//  `SyncApplier`; nothing here decides anything.
//
//  Every write here bypasses `addCalendarEvent` / `updateCalendarEvent` /
//  `delete(_:)` on purpose: those fire `onCalendarEventRecordCompleted` and
//  `calendarEventRecorded` (the SkillAnalysis and TokenInference entry
//  points) or stop a running timer, and a row that arrived from another
//  device is not a new completion on this one. Whole arrays are replaced
//  once, the restore precedent, so foreign-frame rows are stored exactly as
//  they came (`mutateCalendarEvent`'s rebase seam is for local edits).
//  Nothing here saves; `SyncApplier` commits each slot once per page.
//

import Foundation

extension EventStore {

    /// Applies one page of remote changes. See `SyncApplier`.
    func applyRemote(_ page: RemotePage, context: SyncApplyContext) -> SyncApplyOutcome {
        SyncApplier.apply(page, to: self, context: context)
    }

    // MARK: - Pass 2, in memory

    /// Adopted calendar rows replace their local row in place (or append),
    /// then each tombstoned event runs step 1 of its delete cascade — the
    /// same in-memory step `deleteCalendarEvent` / `deleteRecurringCalendarEvent
    /// (scope: .all)` take, without staging any image file.
    func applyRemoteCalendarRows(adopts: [Event], deletions: [Event]) {
        markRemoteCreations(adopts)
        if !adopts.isEmpty {
            rawCalendarEvents = Self.replacingOrAppending(rawCalendarEvents, with: adopts)
        }
        for event in deletions {
            EventDeletionMotionRegistry.shared.mark(
                event.isRecurringSeries ? recurringDeletionMotionIDs(series: event) : [event.id],
                source: .remote
            )
            if event.isRecurringSeries {
                removeRecurringSeriesInMemory(event, occurrenceDay: Self.cascadeDay(for: event), stageAssets: false)
            } else {
                removeCalendarEventInMemory(forDeletionOf: event)
            }
        }
    }

    /// Rows this device has never seen were created elsewhere — unless the
    /// page is an import (first sync, restore), or the row is an exception
    /// instance, which an edit of a series occurrence mints.
    private func markRemoteCreations(_ adopts: [Event]) {
        let registry = EventCreationMotionRegistry.shared
        guard !adopts.isEmpty, registry.isEnabled() else { return }
        let known = Set(rawCalendarEvents.map(\.id))
        let arrivals = adopts.filter { !known.contains($0.id) && $0.recurrenceParentId == nil }
        guard !arrivals.isEmpty else { return }
        guard arrivals.count <= EventCreationMotionRegistry.maxRemoteArrivals else {
            EventCreationMotionLog.append("skip remote arrivals=\(arrivals.count) reason=import")
            return
        }
        registry.mark(arrivals.map(\.id), source: .remote)
    }

    /// Step 3 of the delete cascade for one remote tombstone, in memory:
    /// the interrupt timeline items, feedback and logs the user-initiated
    /// delete would prune. Call only after the calendar commit returned true.
    func pruneRecordsInMemoryAfterRemoteDeletion(of event: Event) {
        if event.isRecurringSeries {
            let day = Self.cascadeDay(for: event)
            pruneFeedbackInMemory(afterDeletingSeries: event, occurrenceDate: day, scope: .all)
            pruneLogRecordsInMemory(afterDeletingSeries: event, occurrenceDate: day, scope: .all)
        } else {
            if event.isInterrupt { pruneInterruptTimelineItemsInMemory(for: event.id) }
            pruneFeedbackInMemory(afterDeleting: event)
            pruneLogRecordsInMemory(afterDeleting: event)
        }
    }

    /// A todo tombstone removes the row and nothing else: `delete(_:)`
    /// would stop a linked timer, which records a completion.
    func applyRemoteTodoRows(adopts: [Event], removing ids: Set<String>) {
        guard !adopts.isEmpty || !ids.isEmpty else { return }
        var next = events.filter { !ids.contains($0.id.uuidString) }
        next = Self.replacingOrAppending(next, with: adopts)
        events = next
    }

    /// Logs keyed by their wire id: a record whose event is not local is
    /// still inserted (the feed interleaves the nine tables by seq, so the
    /// event may arrive in a later page), which `upsertLogRecord` would drop.
    func applyRemoteLogRows(
        adopts: [String: CalendarEventLogRecord],
        removing ids: Set<String>,
        wireId: (CalendarOccurrenceKey) -> String
    ) {
        guard !adopts.isEmpty || !ids.isEmpty else { return }
        calendarEventLogRecords = Self.applyingRecords(calendarEventLogRecords, adopts: adopts,
                                                       removing: ids, wireId: wireId)
    }

    func applyRemoteFeedbackRows(
        adopts: [String: CalendarEventFeedbackRecord],
        removing ids: Set<String>,
        wireId: (CalendarOccurrenceKey) -> String
    ) {
        guard !adopts.isEmpty || !ids.isEmpty else { return }
        calendarEventFeedbackRecords = Self.applyingRecords(calendarEventFeedbackRecords, adopts: adopts,
                                                            removing: ids, wireId: wireId)
    }

    func applyRemoteListRows(adopts: [TodoList], removing ids: Set<String>) {
        guard !adopts.isEmpty || !ids.isEmpty else { return }
        var next = todoLists.filter { !ids.contains($0.id.uuidString) }
        for list in adopts {
            if let index = next.firstIndex(where: { $0.id == list.id }) {
                next[index] = list
            } else {
                next.append(list)
            }
        }
        todoLists = next
    }

    // MARK: - Helpers

    /// The day a `.all` cascade is handed. `.all` ignores it when choosing
    /// what to remove; it only has to be a day.
    private static func cascadeDay(for event: Event) -> Date {
        Calendar.current.startOfDay(for: event.primaryTimeRange?.start ?? event.createdAt)
    }

    private static func replacingOrAppending(_ rows: [Event], with adopts: [Event]) -> [Event] {
        var next = rows
        var index: [UUID: Int] = [:]
        for (offset, event) in next.enumerated() where index[event.id] == nil { index[event.id] = offset }
        for event in adopts {
            if let at = index[event.id] {
                next[at] = event
            } else {
                index[event.id] = next.count
                next.append(event)
            }
        }
        return next
    }

    private static func applyingRecords<T: OccurrenceRecord>(
        _ records: [T],
        adopts: [String: T],
        removing ids: Set<String>,
        wireId: (CalendarOccurrenceKey) -> String
    ) -> [T] {
        var next: [T] = []
        next.reserveCapacity(records.count + adopts.count)
        var placed: Set<String> = []
        for record in records {
            let id = wireId(record.id)
            if ids.contains(id) { continue }
            if let incoming = adopts[id] {
                if placed.insert(id).inserted { next.append(incoming) }
                continue
            }
            next.append(record)
        }
        for (id, incoming) in adopts.sorted(by: { $0.key < $1.key }) where !placed.contains(id) {
            next.append(incoming)
        }
        return next
    }
}
